class Api::V1::Whatsapp::AuthorizationsController < Api::V1::BaseController
  require_permissions({
    index: 'whatsapp_authorizations.read',
    show: 'whatsapp_authorizations.read',
    create: 'whatsapp_authorizations.create',
    update: 'whatsapp_authorizations.update',
    destroy: 'whatsapp_authorizations.delete'
  })
  respond_to :json
  include HTTParty
  

  def create
    Rails.logger.info "WhatsApp authorization controller called with params: #{filtered_params_for_log.inspect}"

    return render_missing_params_error unless valid_params?

    begin
      resolve_waba_id_if_needed
      access_token = exchange_authorization_code
      business_data, phones_data = fetch_business_and_phone_data(access_token)
      response_data = build_response_data(access_token, business_data, phones_data)

      Rails.logger.info "Sending successful response with data: #{response_data.inspect}"
      success_response(data: response_data, message: 'WhatsApp authorization completed successfully')
    rescue StandardError => e
      handle_authorization_error(e)
    end
  end

  private

  # Fix #84: aceptar flujo code (server-side) o access_token (Embedded Signup con config_id).
  # Con access_token el waba_id/business_account_id pueden venir vacíos y se resuelven vía debug_token.
  def valid_params?
    has_credential = authorization_code.present? || access_token_param.present?
    return false unless has_credential

    return true if access_token_param.present?

    business_account_id.present? && waba_id.present?
  end

  def authorization_code
    @authorization_code ||= params[:code]
  end

  def access_token_param
    @access_token_param ||= params[:access_token] || params[:user_access_token]
  end

  def business_account_id
    @business_account_id ||= params[:business_account_id]
  end

  def waba_id
    @waba_id ||= params[:waba_id]
  end

  def render_missing_params_error
    log_missing_params
    error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Missing required parameters', status: :bad_request)
  end

  def log_missing_params
    Rails.logger.error 'Missing required parameters: ' \
                       "code=#{authorization_code.present?}, " \
                       "access_token=#{access_token_param.present?}, " \
                       "business_account_id=#{business_account_id.present?}, " \
                       "waba_id=#{waba_id.present?}"
  end

  def filtered_params_for_log
    params.to_unsafe_h.except(:code, :access_token, :user_access_token).merge(
      code_present: authorization_code.present?,
      access_token_present: access_token_param.present?
    )
  end

  def resolve_waba_id_if_needed
    return if waba_id.present?
    return unless access_token_param.present?

    resolved = resolve_waba_id_from_token(access_token_param)
    @waba_id = resolved
    @business_account_id = resolved if business_account_id.blank?
    Rails.logger.info "Resolved WABA ID from token: #{resolved}"
  end

  def resolve_waba_id_from_token(short_lived_token)
    debug = HTTParty.get(
      "https://graph.facebook.com/#{api_version}/debug_token",
      query: { input_token: short_lived_token, access_token: app_access_token }
    )
    unless debug.success?
      Rails.logger.error "debug_token failed: #{debug.code} - #{debug.body}"
      raise StandardError, "Failed to debug token: #{debug.body}"
    end
    scopes = debug.parsed_response.dig('data', 'granular_scopes') || []
    waba_scope = scopes.find { |s| s['scope'] == 'whatsapp_business_management' }
    ids = waba_scope ? (waba_scope['target_ids'] || []) : []
    raise StandardError, 'No WABA scope found in token' if ids.empty?

    # Preferir el waba_id que mandó el front si está dentro de los autorizados
    return waba_id if waba_id.present? && ids.include?(waba_id)

    ids.first
  end

  def app_access_token
    "#{app_id}|#{app_secret}"
  end

  def exchange_authorization_code
    return exchange_short_lived_token if authorization_code.blank? && access_token_param.present?

    Rails.logger.info 'Making Facebook API call to exchange code for access token...'

    response = HTTParty.post(token_exchange_url, token_exchange_request_options)
    log_token_response(response)

    raise StandardError, "Failed to exchange code: #{response.body}" unless response.success?

    response.parsed_response['access_token']
  end

  def token_exchange_url
    "https://graph.facebook.com/#{api_version}/oauth/access_token"
  end

  def token_exchange_request_options
    {
      body: token_exchange_body.to_json,
      headers: { 'Content-Type' => 'application/json' }
    }
  end

  def token_exchange_body
    {
      client_id: app_id,
      client_secret: app_secret,
      code: authorization_code,
      grant_type: 'authorization_code'
    }
  end

  def log_token_response(response)
    Rails.logger.info "Facebook token response status: #{response.code}"
    Rails.logger.info "Facebook token response body: #{response.body}"
  end

  # Fix #84: flujo accessToken (Embedded Signup con config_id).
  # Cambia short-lived user token por long-lived vía fb_exchange_token.
  def exchange_short_lived_token
    Rails.logger.info 'Exchanging short-lived access token via fb_exchange_token...'

    response = HTTParty.get(
      "https://graph.facebook.com/#{api_version}/oauth/access_token",
      query: {
        grant_type: 'fb_exchange_token',
        client_id: app_id,
        client_secret: app_secret,
        fb_exchange_token: access_token_param
      }
    )
    log_token_response(response)

    raise StandardError, "Failed to exchange token: #{response.body}" unless response.success?

    token = response.parsed_response['access_token']
    raise StandardError, "No access token in response: #{response.body}" if token.blank?

    token
  end

  def fetch_business_and_phone_data(access_token)
    business_data = fetch_business_data(access_token)
    phones_data = fetch_phone_numbers_data(access_token)

    validate_api_responses(business_data, phones_data)

    [business_data.parsed_response, phones_data.parsed_response['data']]
  end

  def fetch_business_data(access_token)
    Rails.logger.info "Fetching business account details for ID: #{waba_id}"

    HTTParty.get(
      "https://graph.facebook.com/#{api_version}/#{waba_id}",
      query: { fields: 'id,name,currency,owner_business_info', access_token: access_token }
    )
  end

  def fetch_phone_numbers_data(access_token)
    Rails.logger.info "Fetching phone numbers for business account: #{waba_id}"

    HTTParty.get(
      "https://graph.facebook.com/#{api_version}/#{waba_id}/phone_numbers",
      query: { fields: phone_number_fields, access_token: access_token }
    )
  end

  def phone_number_fields
    'id,cc,country_dial_code,display_phone_number,verified_name,' \
      'status,quality_rating,search_visibility,platform_type,code_verification_status'
  end

  def validate_api_responses(business_response, phones_response)
    return if business_response.success? && phones_response.success?

    log_api_response_errors(business_response, phones_response)
    raise StandardError, 'Failed to fetch business account details'
  end

  def log_api_response_errors(business_response, phones_response)
    Rails.logger.error 'Failed to fetch business details or phone numbers'
    Rails.logger.error "Business response: #{business_response.code} - #{business_response.body}"
    Rails.logger.error "Phones response: #{phones_response.code} - #{phones_response.body}"
  end

  def build_response_data(access_token, business_data, phones_data)
    first_phone = phones_data&.first
    Rails.logger.info 'Preparing response data...'

    {
      access_token: access_token,
      business_account_id: business_account_id,
      waba_id: waba_id,
      inbox_name: business_data['name'] || 'WhatsApp Business',
      phone_number: first_phone ? first_phone['display_phone_number'] : '',
      phone_number_id: first_phone ? first_phone['id'] : ''
    }
  end

  def handle_authorization_error(error)
    Rails.logger.error "Exception in WhatsApp authorization: #{error.class} - #{error.message}"
    Rails.logger.error error.backtrace.join("\n")
    error_response(ApiErrorCodes::INTERNAL_ERROR, 'Internal server error', status: :internal_server_error)
  end

  def api_version
    @api_version ||= GlobalConfigService.load('WP_API_VERSION', 'v23.0')
  end

  def app_id
    @app_id ||= GlobalConfigService.load('WP_APP_ID', '')
  end

  def app_secret
    @app_secret ||= GlobalConfigService.load('WP_APP_SECRET', '')
  end

end
