require "lita"
require "forwardable"
require "tmpdir"
require "fileutils"
require_relative "../../lita_versioner"
require_relative "../../lita_versioner/jenkins_http"
require "shellwords"

module Lita
  module Handlers
    class BumpbotHandler < Handler
      # include LitaVersioner so we get the constants from it (so we can use the
      # classes easily here and in subclasses)
      include LitaVersioner

      namespace "versioner"

      config :jenkins_username, required: true
      config :jenkins_api_token, required: true
      config :jenkins_endpoint, default: "http://manhattan.ci.chef.co/"
      config :polling_interval, default: false
      config :trigger_real_builds, default: false
      config :default_inform_channel, default: "chef-notify"
      config :projects, default: {}
      config :cache_directory, default: "#{Dir.tmpdir}/lita_versioner"
      config :sandbox_directory, default: "#{Dir.tmpdir}/lita_versioner/sandbox"
      config :debug_lines_in_pm, default: true

      attr_accessor :project_name
      attr_reader :handler_name
      attr_reader :response
      attr_accessor :http_response

      #
      # Unique ID for the handler
      #
      attr_reader :handler_id

      def self.inherited(klass)
        super
        klass.namespace("versioner")
      end

      @@handler_mutex = Mutex.new
      @@handler_id = 0

      # Give the handler a monotonically increasing ID
      def initialize(*args)
        super
        @@handler_mutex.synchronize do
          @@handler_id += 1
          @handler_id = @@handler_id.to_s
        end
      end

      def project_repo
        @project_repo ||= ProjectRepo.new(self)
      end

      def cleanup
        FileUtils.rm_rf(sandbox_directory)
      end

      #
      # Define a chat route with the given command name and arguments.
      #
      # A bumpbot chat command generally looks like @julia command project *args
      #
      # @param command [String] name of the command, e.g. 'build'.
      # @param method_sym [Symbol] method to dispatch to.  No arguments are passed.
      # @param help [Hash : String -> String] usage help strings, e.g.
      #   {
      #     'EXTRA_ARG_NAME' => 'some usage',
      #     'DIFFERENT_ARG SEQUENCE HERE' => 'different usage'
      #   }
      # @param max_args [Int] Maximum number of extra arguments that this command takes.
      #
      def self.command_route(command, help, max_args: 0, &block)
        help = { "" => help } unless help.is_a?(Hash)

        complete_help = {}
        help.each do |arg, text|
          complete_help["#{command} PROJECT #{arg}".strip] = text
        end
        route(/^#{command}\b/, nil, command: true, help: complete_help) do |response|
          # This block will be instance-evaled in the context of the handler
          # instance - so we can set instance variables etc.
          begin
            init_command(command, response, complete_help, max_args)
            instance_exec(*command_args, &block)
            cleanup
          rescue ErrorAlreadyReported
            debug("Sandbox: #{sandbox_directory}")
          rescue
            msg = "Unhandled error while working on \"#{response.message.body}\":\n" +
              "```#{$!}\n#{$!.backtrace.join("\n")}```."
            error(msg)
            debug("Sandbox: #{sandbox_directory}")
          end
        end
      end

      #
      # Cache directory for this handler instance to
      #
      def sandbox_directory
        @sandbox_directory ||= begin
          dir = File.join(config.sandbox_directory, handler_id)
          FileUtils.rm_rf(dir)
          FileUtils.mkdir_p(dir)
          dir
        end
      end

      #
      # Callback wrapper for non-command handlers.
      #
      # @param title The event title.
      # @return whatever the provided block returns.
      #
      def handle_event(title)
        init_event(title)
        yield
        cleanup
      rescue ErrorAlreadyReported
        debug("Sandbox: #{sandbox_directory}")
      rescue
        msg = "Unhandled error while working on \"#{title}\":\n" +
          "```#{$!}\n#{$!.backtrace.join("\n")}."
        debug("Sandbox: #{sandbox_directory}")
        error(msg)
      end

      def run_command(command, timeout: 3600, **options)
        Bundler.with_clean_env do
          options[:timeout] = timeout

          command = Shellwords.join(command) if command.is_a?(Array)
          debug("Running \"#{command}\" with #{options}")
          shellout = Mixlib::ShellOut.new(command, options)
          shellout.run_command
          shellout.error!
          debug("STDOUT:\n```#{shellout.stdout}```\n")
          debug("STDERR:\n```#{shellout.stderr}```\n") if shellout.stderr != ""
          shellout
        end
      end

      #
      # Trigger a Jenkins build on the given git ref.
      #
      def trigger_build(pipeline, git_ref)
        debug("Kicking off a build for #{pipeline} at ref #{git_ref}.")

        unless config.trigger_real_builds
          warn("Would have triggered a build, but config.trigger_real_builds is false.")
          return true
        end

        jenkins = JenkinsHTTP.new(base_uri: config.jenkins_endpoint,
                                  username: config.jenkins_username,
                                  api_token: config.jenkins_api_token)

        begin
          jenkins.post("/job/#{pipeline}/buildWithParameters",
            "GIT_REF" => git_ref,
            "EXPIRE_CACHE" => false,
            "INITIATED_BY" => response ? response.user.mention_name : "BumpBot"
          )
        rescue JenkinsHTTP::JenkinsHTTPError => e
          error("Sorry, received HTTP error when kicking off the build!\n#{e}")
          return false
        end

        return true
      end

      #
      # Optional command arguments if this handler is a command handler.
      #
      def command_args
        @command_args ||= response.args.drop(1) if response
      end

      def error!(message, status: "500")
        error(message, status: status)
        raise ErrorAlreadyReported.new(message)
      end

      def error(message, status: "500")
        if http_response
          http_response.status = status
        end
        send_message("**ERROR:** #{message}")
        log_each_line(:error, message)
      end

      def warn(message)
        send_message("WARN: #{message}")
        log_each_line(:warn, message)
      end

      def info(message)
        send_message(message)
        log_each_line(:info, message)
      end

      # debug messages are only sent to users in private messages
      def debug(message)
        send_message(message) if response && response.private_message? && config.debug_lines_in_pm
        log_each_line(:debug, message)
      end

      def project
        projects[project_name]
      end

      def projects
        config.projects
      end

      class ErrorAlreadyReported < StandardError
        attr_accessor :cause

        def initialize(message = nil, cause = nil)
          super(message)
          self.cause = cause
        end
      end

      private

      #
      # Initialize this handler as a chat command handler.
      #
      def init_command(command, response, help, max_args)
        @handler_name = command
        @response = response
        error!("No project specified!\n#{usage(help)}") if response.args.empty?
        @project_name = response.args[0]
        debug("Handling command #{command.inspect}")
        unless project
          error!("Invalid project. Valid projects: #{projects.keys.join(", ")}.\n#{usage(help)}")
        end
        if command_args.size > max_args
          error!("Too many arguments (#{command_args.size + 1} for #{max_args + 1})!\n#{usage(help)}")
        end
      end

      #
      # Initialize this handler as a chat command handler.
      #
      def init_event(name)
        @handler_name = name
        @response = nil
        debug("Handling event #{name}")
      end

      #
      # Usage for this command.
      #
      def usage(help)
        usage = "Usage: "
        usage << "\n" if help.size > 1
        usage_lines = help.map { |command, text| "#{command}   - #{text}" }
        usage << usage_lines.join("\n")
      end

      #
      # Log to the default Lita logger with a custom per-line prefix.
      #
      # This is help identify what command or handler a particular message came
      # from when reading syslog.
      #
      def log_each_line(log_method, message)
        prefix = "<#{handler_name}>{#{project_name || "unknown"}} "
        message.to_s.each_line do |l|
          log.public_send(log_method, "#{prefix}#{l.chomp}")
        end
      end

      #
      # Send a message to the appropriate place.
      #
      # - For Slack messages, errors are sent to the originating user via respond
      # - For events, errors are sent to the project.channel_name
      #
      def send_message(message)
        if response
          response.reply(message)
        else
          room = message_source
          robot.send_message(room, message) if room
        end
        if http_response
          message = "#{message}\n" unless message.end_with?("\n")
          http_response.body << message
        end
      end

      def message_source
        if project && project[:inform_channel]
          @project_room = source_by_name(project[:inform_channel]) unless defined?(@project_room)
          @project_room
        else
          @default_room = source_by_name(config.default_inform_channel) unless defined?(@default_room)
          @default_room
        end
      end

      def source_by_name(channel_name)
        room = Lita::Room.fuzzy_find(channel_name)
        source = Lita::Source.new(room: room) if room
        log_each_line(:error, "Unable to resolve ##{channel_name}.") unless source
        source
      end
    end

    Lita.register_handler(BumpbotHandler)
  end
end
