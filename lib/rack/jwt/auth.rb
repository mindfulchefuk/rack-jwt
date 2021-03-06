# frozen_string_literal: true

require 'jwt'

module Rack
  module JWT
    # Authentication middleware
    class Auth
      attr_reader :secret
      attr_reader :verify
      attr_reader :options
      attr_reader :cookie_name
      attr_reader :exclude

      SUPPORTED_ALGORITHMS = [
        'none',
        'HS256',
        'HS384',
        'HS512',
        'RS256',
        'RS384',
        'RS512',
        'ES256',
        'ES384',
        'ES512',
        ('ED25519' if defined?(RbNaCl))
      ].compact.freeze

      DEFAULT_ALGORITHM = 'HS256'

      # The last segment gets dropped for 'none' algorithm since there is no
      # signature so both of these patterns are valid. All character chunks
      # are base64url format and periods.
      #   Bearer abc123.abc123.abc123
      #   Bearer abc123.abc123.
      BEARER_TOKEN_REGEX = %r{
        ^Bearer\s(       # starts with Bearer and a single space
        [a-zA-Z0-9\-_]+\.  # 1 or more chars followed by a single period
        [a-zA-Z0-9\-_]+\.  # 1 or more chars followed by a single period
        [a-zA-Z0-9\-_]*    # 0 or more chars, no trailing chars
        )$
      }x.freeze

      # Initialization should fail fast with an ArgumentError
      # if any args are invalid.
      def initialize(app, opts = {})
        @app          = app
        @secret       = opts.fetch(:secret, nil)
        @verify       = opts.fetch(:verify, true)
        @options      = opts.fetch(:options, {})
        @cookie_name  = opts.dig(:options, :cookie_name)
        @exclude      = opts.fetch(:exclude, [])

        @secret = @secret&.strip if @secret.is_a?(String)
        @options[:algorithm] = DEFAULT_ALGORITHM if @options[:algorithm].nil?

        check_secret_type!
        check_secret!
        check_secret_and_verify_for_none_alg!
        check_verify_type!
        check_options_type!
        check_valid_algorithm!
        check_exclude_type!
      end

      def call(env)
        auth_is_required = !path_matches_excluded_path?(env)

        if auth_is_required
          if auth_cookie_enabled? && missing_auth_cookie?(env) && missing_auth_header?(env)
            return return_error('Missing token cookie and Authorization header')
          end
          if auth_cookie_enabled? && empty_auth_cookie?(env)
            return return_error('Empty token cookie')
          end
          if auth_cookie_disabled? && missing_auth_header?(env)
            return return_error('Missing Authorization header')
          end
          if auth_cookie_disabled? && invalid_auth_header?(env)
            return return_error('Invalid Authorization header format')
          end
        end

        cookie_token = extract_cookie_token(env)
        header_token = extract_header_token(env)

        if auth_is_required || cookie_token || header_token
          verify_token(cookie_token || header_token, env)
        end

        @app.call(env)
      rescue ::JWT::VerificationError
        return_error('Invalid JWT token : Signature Verification Error')
      rescue ::JWT::ExpiredSignature
        return_error('Invalid JWT token : Expired Signature (exp)')
      rescue ::JWT::IncorrectAlgorithm
        return_error('Invalid JWT token : Incorrect Key Algorithm')
      rescue ::JWT::ImmatureSignature
        return_error('Invalid JWT token : Immature Signature (nbf)')
      rescue ::JWT::InvalidIssuerError
        return_error('Invalid JWT token : Invalid Issuer (iss)')
      rescue ::JWT::InvalidIatError
        return_error('Invalid JWT token : Invalid Issued At (iat)')
      rescue ::JWT::InvalidAudError
        return_error('Invalid JWT token : Invalid Audience (aud)')
      rescue ::JWT::InvalidSubError
        return_error('Invalid JWT token : Invalid Subject (sub)')
      rescue ::JWT::InvalidJtiError
        return_error('Invalid JWT token : Invalid JWT ID (jti)')
      rescue ::JWT::DecodeError
        return_error('Invalid JWT token : Decode Error')
      end

      private

      # extract the token from the Authorization: Bearer header
      # with a regex capture group.
      def extract_header_token(env)
        BEARER_TOKEN_REGEX.match(env['HTTP_AUTHORIZATION'])&.[](1)
      end

      def verify_token(token, env)
        decoded_token = Token.decode(token, @secret, @verify, @options)
        env['jwt.payload'] = decoded_token.first
        env['jwt.header'] = decoded_token.last
      end

      def check_secret_type!
        return if Token.secret_of_valid_type?(@secret)

        raise ArgumentError, 'secret argument must be a valid type'
      end

      def check_secret!
        return unless @secret.nil? || (@secret.is_a?(String) && @secret.empty?)
        return if @options[:algorithm] == 'none'

        raise ArgumentError, 'secret argument can only be nil/empty for the "none" algorithm'
      end

      def check_secret_and_verify_for_none_alg!
        return unless @options && @options[:algorithm] && @options[:algorithm] == 'none'
        return if @secret.nil? && @verify.is_a?(FalseClass)

        raise ArgumentError, 'when "none" the secret must be "nil" and verify "false"'
      end

      def check_verify_type!
        return if verify.is_a?(TrueClass) || verify.is_a?(FalseClass)

        raise ArgumentError, 'verify argument must be true or false'
      end

      def check_options_type!
        raise ArgumentError, 'options argument must be a Hash' unless options.is_a?(Hash)
      end

      def check_valid_algorithm!
        unless @options &&
               @options[:algorithm] &&
               SUPPORTED_ALGORITHMS.include?(@options[:algorithm])
          raise ArgumentError, 'algorithm argument must be a supported type'
        end
      end

      def check_exclude_type!
        raise ArgumentError, 'exclude argument must be an Array' unless exclude.is_a?(Array)

        exclude.each do |exclusion|
          raise ArgumentError, 'each exclude Array element must not be empty' if exclusion.empty?

          case exclusion
          when Hash
            validate_exclude_hash(exclusion)
          when String
            validate_exclude_string(exclusion)
          else
            raise ArgumentError, 'each exclude Array element must be a Hash or String'
          end
        end
      end

      def validate_exclude_hash(exclusion)
        if %i(methods path).to_set < exclusion.keys.to_set
          raise ArgumentError, 'each exclude Array element must contain keys: path and methods'
        end

        unless exclusion[:path].start_with?('/')
          raise ArgumentError, 'each exclude Array element path value must start with a /'
        end

        unless exclusion[:methods] == :all || exclusion[:methods].is_a?(Array)
          raise ArgumentError, 'each exclude Array element methods value must be :all or an array'
        end
      end

      def validate_exclude_string(exclusion)
        unless exclusion.start_with?('/')
          raise ArgumentError, 'each exclude Array element must start with a /'
        end
      end

      def path_matches_excluded_path?(env)
        exclude.any? do |exclusion|
          case exclusion
          when String
            env['PATH_INFO'].start_with?(exclusion)
          when Hash
            env['PATH_INFO'].start_with?(exclusion[:path]) &&
            (
              exclusion[:methods] == :all ||
              exclusion[:methods] == [:all] ||
              exclusion[:methods].include?(env['REQUEST_METHOD'].downcase.to_sym)
            )
          else
            false
          end
        end
      end

      def valid_auth_header?(env)
        env['HTTP_AUTHORIZATION'] =~ BEARER_TOKEN_REGEX
      end

      def invalid_auth_header?(env)
        !valid_auth_header?(env)
      end

      def missing_auth_header?(env)
        env['HTTP_AUTHORIZATION'].nil? || env['HTTP_AUTHORIZATION'].strip.empty?
      end

      def auth_cookie_enabled?
        cookie_name != nil
      end

      def auth_cookie_disabled?
        !auth_cookie_enabled?
      end

      def extract_cookie_token(env)
        cookie = cookies(env)[cookie_name]
        cookie.nil? || cookie.empty? ? nil : cookie
      end

      def cookies(env)
        Rack::Utils.parse_cookies(env)
      end

      def empty_auth_cookie?(env)
        cookies(env)[cookie_name]&.strip == ''
      end

      def missing_auth_cookie?(env)
        !cookies(env).key?(cookie_name)
      end

      def return_error(message)
        body    = { error: message }.to_json
        headers = { 'Content-Type' => 'application/json' }

        [401, headers, [body]]
      end
    end
  end
end
