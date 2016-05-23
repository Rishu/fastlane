module Fastlane
  class PluginManager
    PLUGINSFILE_NAME = "Pluginfile".freeze
    DEFAULT_GEMFILE_PATH = "Gemfile".freeze
    GEMFILE_SOURCE_LINE = "source \"https://rubygems.org\"\n"
    FASTLANE_PLUGIN_PREFIX = "fastlane-plugin-"

    #####################################################
    # @!group Reading the files and their paths
    #####################################################

    def gemfile_path
      # This is pretty important, since we don't know what kind of
      # Gemfile the user has (e.g. Gemfile, gems.rb, or custom env variable)
      Bundler::SharedHelpers.default_gemfile.to_s
    rescue Bundler::GemfileNotFound
      nil
    end

    def pluginsfile_path
      File.join(FastlaneFolder.path, PLUGINSFILE_NAME) if FastlaneFolder.path
    end

    def gemfile_content
      File.read(gemfile_path) if gemfile_path && File.exist?(gemfile_path)
    end

    def pluginsfile_content
      File.read(pluginsfile_path) if pluginsfile_path && File.exist?(pluginsfile_path)
    end

    #####################################################
    # @!group Helpers
    #####################################################

    def self.plugin_prefix
      FASTLANE_PLUGIN_PREFIX
    end

    # Returns an array of gems that are added to the Gemfile or Pluginfile
    def available_gems
      return [] unless gemfile_path
      dsl = Bundler::Dsl.evaluate(gemfile_path, nil, true)
      return dsl.dependencies.map(&:name)
    end

    # Returns an array of fastlane plugins that are added to the Gemfile or Pluginfile
    # The returned array contains the string with their prefixes (e.g. fastlane-plugin-xcversion)
    def available_plugins
      available_gems.keep_if do |current|
        current.start_with?(self.class.plugin_prefix)
      end
    end

    # Check if a plugin is added as dependency to either the
    # Gemfile or the Pluginfile
    def plugin_is_added_as_dependency?(plugin_name)
      UI.user_error!("fastlane plugins must start with '#{self.class.plugin_prefix}' string") unless plugin_name.start_with?(self.class.plugin_prefix)
      return available_plugins.include?(plugin_name)
    end

    #####################################################
    # @!group Modifying dependencies
    #####################################################

    def add_dependency(plugin_name)
      plugin_name = self.class.plugin_prefix + plugin_name unless plugin_name.start_with?(self.class.plugin_prefix)

      unless plugin_is_added_as_dependency?(plugin_name)
        content = pluginsfile_content || "# Autogenerated by fastlane\n\n"

        line_to_add = "gem '#{plugin_name}'"
        line_to_add += gem_dependency_suffix(plugin_name)
        UI.verbose("Adding line: #{line_to_add}")

        content += "#{line_to_add}\n"
        File.write(pluginsfile_path, content)
        UI.success("Plugin '#{plugin_name}' was added.")
      end

      # We do this *after* creating the Plugin file
      # Since `bundle exec` would be broken if something fails on the way
      ensure_plugins_attached!

      true
    end

    # Get a suffix (e.g. `path` or `git` for the gem dependency)
    def gem_dependency_suffix(plugin_name)
      return "" unless self.class.fetch_gem_info_from_rubygems(plugin_name).nil?

      selection_git_url = "Git URL"
      selection_path = "Local Path"
      selection_rubygems = "RubyGems.org ('#{plugin_name}' seems to not be available there)"
      selection = UI.select(
        "Seems like the plugin is not available on RubyGems, what do you want to do?",
        [selection_git_url, selection_path, selection_rubygems]
      )

      if selection == selection_git_url
        git_url = UI.input('Please enter the URL to the plugin, including the protocol (e.g. https:// or git://)')
        return ", git: '#{git_url}'"
      elsif selection == selection_path
        path = UI.input('Please enter the relative path to the plugin you want to use. It has to point to the directory containing the .gemspec file')
        return ", path: '#{path}'"
      elsif selection == selection_rubygems
        return ""
      else
        UI.user_error!("Unknown input #{selection}")
      end
    end

    # Modify the user's Gemfile to load the plugins
    def attach_plugins_to_gemfile!(path_to_gemfile)
      content = gemfile_content || GEMFILE_SOURCE_LINE

      # We have to make sure fastlane is also added to the Gemfile, since we now use
      # bundler to run fastlane
      content += "\ngem 'fastlane'\n" unless available_gems.include?('fastlane')
      content += "\n#{self.class.code_to_attach}\n"

      File.write(path_to_gemfile, content)
    end

    #####################################################
    # @!group Accessing RubyGems
    #####################################################

    def self.fetch_gem_info_from_rubygems(gem_name)
      require 'open-uri'
      require 'json'
      url = "https://rubygems.org/api/v1/gems/#{gem_name}.json"
      begin
        JSON.parse(open(url).read)
      rescue
        nil
      end
    end

    #####################################################
    # @!group Installing and updating dependencies
    #####################################################

    # Warning: This will exec out
    # This is necessary since the user might be prompted for their password
    def install_dependencies!
      # Using puts instead of `UI` to have the same style as the `echo`
      puts "Installing plugin dependencies..."
      ensure_plugins_attached!
      with_clean_bundler_env do
        cmd = "bundle install"
        cmd << " --quiet" unless $verbose
        cmd << " && echo 'Successfully installed plugins'"
        exec(cmd)
      end
    end

    # Warning: This will exec out
    # This is necessary since the user might be prompted for their password
    def update_dependencies!
      puts "Updating plugin dependencies..."
      ensure_plugins_attached!
      with_clean_bundler_env do
        cmd = "bundle update"
        cmd << " --quiet" unless $verbose
        cmd << " && echo 'Successfully updated plugins'"
        exec(cmd)
      end
    end

    def with_clean_bundler_env
      # There is an interesting problem with using exec to call back into Bundler
      # The `bundle ________` command that we exec, inherits all of the Bundler
      # state we'd already built up during this run. That was causing the command
      # to fail, telling us to install the Gem we'd just introduced, even though
      # that is exactly what we are trying to do!
      #
      # Bundler.with_clean_env solves this problem by resetting Bundler state before the
      # exec'd call gets merged into this process.

      Bundler.with_clean_env do
        yield if block_given?
      end
    end

    #####################################################
    # @!group Initial setup
    #####################################################

    def setup
      UI.important("It looks like fastlane plugins are not yet set up for this project.")

      path_to_gemfile = gemfile_path || DEFAULT_GEMFILE_PATH

      if gemfile_content.to_s.length > 0
        UI.important("fastlane will modify your existing Gemfile at path '#{path_to_gemfile}'")
      else
        UI.important("fastlane will create a new Gemfile at path '#{path_to_gemfile}'")
      end

      UI.important("This change is neccessary for fastlane plugins to work")

      unless UI.confirm("Can fastlane modify the Gemfile at path '#{path_to_gemfile}' for you?")
        UI.important("Please add the following code to '#{path_to_gemfile}':")
        puts ""
        puts self.class.code_to_attach.magenta # we use `puts` instead of `UI` to make it easier to copy and paste
        UI.user_error!("Please update '#{path_to_gemfile} and run fastlane again")
      end

      attach_plugins_to_gemfile!(path_to_gemfile)
      UI.success("Successfully modified '#{path_to_gemfile}'")
    end

    # The code required to load the Plugins file
    def self.code_to_attach
      "plugins_path = File.join(File.dirname(__FILE__), 'fastlane', '#{PluginManager::PLUGINSFILE_NAME}')\n" \
      "eval(File.read(plugins_path), binding) if File.exist?(plugins_path)"
    end

    # Makes sure, the user's Gemfile actually loads the Plugins file
    def plugins_attached?
      gemfile_path && gemfile_content.include?(self.class.code_to_attach)
    end

    def ensure_plugins_attached!
      return if plugins_attached?
      self.setup
    end

    #####################################################
    # @!group Requiring the plugins
    #####################################################

    # Iterate over all available plugins
    # which follow the naming convention
    #   fastlane-plugin-[plugin_name]
    # This will make sure to load the action
    # and all its helpers
    def self.load_plugins
      @plugin_references = {}

      UI.verbose("Checking if there are any plugins that should be loaded...")

      Gem::Specification.each do |current_gem|
        gem_name = current_gem.name
        next unless gem_name.start_with?(PluginManager.plugin_prefix)

        UI.verbose("Loading '#{gem_name}' plugin")
        begin
          require gem_name.tr("-", "/") # from "fastlane-plugin-xcversion" to "fastlane/plugin/xcversion"

          # We store a collection of the imported plugins
          # This way we can tell which action came from what plugin
          # (a plugin may contain any number of actions)
          references = Fastlane::Xcversion.all_classes.collect do |path|
            next unless path.end_with?("_action.rb")
            File.basename(path).gsub("_action.rb", "").to_sym
          end
          @plugin_references[gem_name] = references.keep_if {|a| !a.nil? }

          # Example value of plugin_references
          # => {"fastlane-plugin-xcversion"=>[:xcversion]}
        rescue => ex
          UI.error("Error loading plugin '#{gem_name}': #{ex}")
        end
      end
    end

    #####################################################
    # @!group Reference between plugins to actions
    #####################################################

    # Connection between plugins and their actions
    # Example value of plugin_references
    # => {"fastlane-plugin-xcversion"=>[:xcversion]}
    def self.plugin_references
      @plugin_references || {}
    end
  end
end