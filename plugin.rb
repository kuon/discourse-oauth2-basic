# name: discourse-oauth2-basic
# about: Generic OAuth2 Plugin
# version: 0.2
# authors: Robin Ward

require_dependency 'auth/oauth2_authenticator.rb'

enabled_site_setting :oauth2_enabled

class OAuth2BasicAuthenticator < ::Auth::OAuth2Authenticator
  def register_middleware(omniauth)
    omniauth.provider :oauth2,
                      name: 'oauth2_basic',
                      setup: lambda {|env|
                        opts = env['omniauth.strategy'].options
                        opts[:client_id] = SiteSetting.oauth2_client_id
                        opts[:client_secret] = SiteSetting.oauth2_client_secret
                        opts[:provider_ignores_state] = true
                        opts[:client_options] = {
                          authorize_url: SiteSetting.oauth2_authorize_url,
                          token_url: SiteSetting.oauth2_token_url
                        }
                        if SiteSetting.oauth2_send_auth_header?
                          opts[:token_params] = {headers: {'Authorization' => basic_auth_header }}
                        end
                      }
  end

  def basic_auth_header
    "Basic " + Base64.strict_encode64("#{SiteSetting.oauth2_client_id}:#{SiteSetting.oauth2_client_secret}")
  end

  def walk_path(fragment, segments)
    first_seg = segments[0]
    return if first_seg.blank? || fragment.blank?
    return nil unless fragment.is_a?(Hash)
    deref = fragment[first_seg] || fragment[first_seg.to_sym]

    return (deref.blank? || segments.size == 1) ? deref : walk_path(deref, segments[1..-1])
  end

  def json_walk(result, user_json, prop)
    path = SiteSetting.send("oauth2_json_#{prop}_path")
    if path.present?
      segments = path.split('.')
      val = walk_path(user_json, segments)
      result[prop] = val if val.present?
    end
  end

  def fetch_user_details(token)
    user_json_url = SiteSetting.oauth2_user_json_url.sub(':token', token)
    user_json = JSON.parse(open(user_json_url, 'Authorization' => "Bearer #{token}" ).read)

    result = {}
    if user_json.present?
      json_walk(result, user_json, :user_id)
      json_walk(result, user_json, :username)
      json_walk(result, user_json, :name)
      json_walk(result, user_json, :email)
    end

    result
  end

  def after_authenticate(auth)
    result = Auth::Result.new
    token = auth['credentials']['token']
    user_details = fetch_user_details(token)

    result.name = user_details[:name]
    result.username = user_details[:username]

    if !SiteSetting.oauth2_force_email_domain.empty?
      result.email = "#{UserNameSuggester.sanitize_username(result.username)}@#{SiteSetting.oauth2_force_email_domain}"
      result.email_valid = true
    else
      result.email = user_details[:email]
      result.email_valid = result.email.present? && SiteSetting.oauth2_email_verified?
    end

    current_info = ::PluginStore.get("oauth2_basic", "oauth2_basic_user_#{user_details[:user_id]}")
    if current_info
      result.user = User.where(id: current_info[:user_id]).first
    elsif SiteSetting.oauth2_email_verified?
      result.user = User.where(email: Email.downcase(result.email)).first
    end

    result.extra_data = {
      oauth2_basic_user_id: user_details[:user_id],
      oauth2_basic_username: user_details[:username]
    }
    result
  end

  def log(info)
    Rails.logger.warn("OAuth2 Debugging: #{info}") if SiteSetting.oauth2_debug_auth
  end

  def after_create_account(user, auth)
    log("After create account for #{user.name}")
    oid = auth[:extra_data][:oauth2_basic_user_id]
    if SiteSetting.oauth2_override_username
      username = auth[:extra_data][:oauth2_basic_username]
      user.name = username
      if SiteSetting.oauth2_store_username_in_title
        user.title = username
      end
      user.username = UserNameSuggester.sanitize_username(username)
      user.save
    end
    unless SiteSetting.oauth2_avatar_url_template.empty?
      log("Importing avatar for user #{user.name}")
      info = {
        username: user.username,
        name: user.name,
        oauth_id: oid,
        user_id: user.id
      }
      log("Info: #{info}")
      url = SiteSetting.oauth2_avatar_url_template % info
      UserAvatar.import_url_for_user(url, user)
    end
    log("Setting plugin rows for user #{user.name}")
    ::PluginStore.set("oauth2_basic", "oauth2_basic_user_oauth_#{user.id}", {oauth_id: oid })
    ::PluginStore.set("oauth2_basic", "oauth2_basic_user_#{oid}", {user_id: user.id })
  end
end

auth_provider title_setting: "oauth2_button_title",
              enabled_setting: "oauth2_enabled",
              authenticator: OAuth2BasicAuthenticator.new('oauth2_basic'),
              message: "OAuth2",
              frame_width: 550,
              frame_height: 600

register_css <<CSS

  button.btn-social.oauth2_basic {
    background-color: #6d6d6d;
  }

CSS
