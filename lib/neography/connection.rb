module Neography
  module WasCreated
  end
  class Connection
    USER_AGENT = "Neography/#{Neography::VERSION}"
    ACTIONS = ["get", "post", "put", "delete"]
    
    attr_accessor :protocol, :server, :port, :directory,
      :cypher_path, :gremlin_path,
      :log_file, :log_enabled, :logger,
      :max_threads,
      :authentication, :username, :password,
      :parser, :client

    def initialize(options = ENV['NEO4J_URL'] || {})
      config = merge_configuration(options)
      save_local_configuration(config)
      @client = HTTPClient.new
      @client.send_timeout = 1200 # 10 minutes
      @client.receive_timeout = 1200
    end

    def configure(protocol, server, port, directory)
      @protocol = protocol
      @server = server
      @port = port
      @directory = directory
    end

    def configuration
      @configuration ||= "#{@protocol}#{@server}:#{@port}#{@directory}/db/data"
    end

    def merge_options(options)
      merged_options = options.merge!(@authentication)
      merged_options[:headers].merge!(@user_agent) if merged_options[:headers]
      merged_options[:headers].merge!('X-Stream' => true) if merged_options[:headers]
      merged_options
    end

    ACTIONS.each do |action|
      define_method(action) do |path, options = {}|
        authenticate(configuration + path)
        evaluate_response(@client.send(action.to_sym, configuration + path, merge_options(options)[:body], merge_options(options)[:headers]))    
      end 
    end

    def authenticate(path)
      @client.set_auth(path, 
                       @authentication[@authentication.keys.first][:username], 
                       @authentication[@authentication.keys.first][:password]) unless @authentication.empty?
    end
    
    private

    def merge_configuration(options)
      options = parse_string_options(options) unless options.is_a? Hash
      config = Neography.configuration.to_hash
      config.merge(options)
    end

    def save_local_configuration(config)
      @protocol       = config[:protocol]
      @server         = config[:server]
      @port           = config[:port]
      @directory      = config[:directory]
      @cypher_path    = config[:cypher_path]
      @gremlin_path   = config[:gremlin_path]
      @log_file       = config[:log_file]
      @log_enabled    = config[:log_enabled]
      @max_threads    = config[:max_threads]
      @parser         = config[:parser]

      @user_agent     = { "User-Agent" => USER_AGENT }

      @authentication = {}
      if config[:authentication]
        @authentication = {
          "#{config[:authentication]}_auth".to_sym => {
            :username => config[:username],
            :password => config[:password]
          }
        }
      end

      if @log_enabled
        @logger = Logger.new(@log_file)
      end
    end

    def evaluate_chunk_response(response, result)
      code = response.code
      return_result(code, result)
    end

    def evaluate_response(response)
      if response.http_header.request_uri.request_uri == "/db/data/batch"
        code, body, parsed = handle_batch(response)
      else
        code = response.code
        body = response.body.force_encoding("UTF-8")
        parsed = false
      end
      return_result(code, body, parsed)
    end

    def handle_batch(response)
      code = 200
      body = @parser.json(response.body.force_encoding("UTF-8"))
      body.each do |result|
        if result["status"] >= 400
          code = result["status"] 
          break
        end
      end
      return code, body, true
    end
    
    def return_result(code, body, parsed)
      case code
      when 200
        @logger.debug "OK, created #{body}" if @log_enabled
        parsed ? body : @parser.json(body)
      when 201
        @logger.debug "OK, created #{body}" if @log_enabled
        r = parsed ? body : @parser.json(body)
        r.extend(WasCreated)
        r
      when 204
        @logger.debug "OK, no content returned" if @log_enabled
        nil
      when 400..500
        handle_4xx_500_response(code, body)
        nil
      end      
    end

    def handle_4xx_500_response(code, body)
      if body.nil? or body == ""
        parsed_body = {"message" => "No error message returned from server.",
                       "stacktrace" => "No stacktrace returned from server." }
      elsif body.is_a? Hash
        parsed_body = body
      elsif body.is_a? Array
        body.each do |result|
          if result["status"] >= 400
            parsed_body = result["body"] || result
            break
          end
        end        
      else
        parsed_body = @parser.json(body)
      end

      message = parsed_body["message"]
      stacktrace = parsed_body["stacktrace"]

      @logger.error "#{code} error: #{body}" if @log_enabled
      raise_errors(code, parsed_body["exception"], message, stacktrace)
    end
    
    def raise_errors(code, exception, message, stacktrace)
      error = nil
      case code
        when 401
          error = UnauthorizedError
        when 409
          error = OperationFailureException
      end

      error ||= case exception
        when /SyntaxException/               ; SyntaxException
        when /this is not a query/           ; SyntaxException
        when /PropertyValueException/        ; PropertyValueException
        when /BadInputException/             ; BadInputException
        when /NodeNotFoundException/         ; NodeNotFoundException
        when /NoSuchPropertyException/       ; NoSuchPropertyException
        when /RelationshipNotFoundException/ ; RelationshipNotFoundException
        when /NotFoundException/             ; NotFoundException
        when /UniquePathNotUniqueException/  ; UniquePathNotUniqueException
        else
          NeographyError
      end
      
      raise error.new(message, code, stacktrace)      
    end

    def parse_string_options(options)
      url = URI.parse(options)
      options = {
        :protocol  => url.scheme + "://",
        :server    => url.host,
        :port      => url.port,
        :directory => url.path,
        :username  => url.user,
        :password  => url.password
      }
      options[:authentication] = 'basic' unless url.user.nil?
      options
    end

  end
end
