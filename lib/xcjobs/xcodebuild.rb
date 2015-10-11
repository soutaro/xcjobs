require 'rake/tasklib'
require 'rake/clean'
require 'open3'
require 'shellwords'
require_relative 'helper'

module XCJobs
  class Xcodebuild < Rake::TaskLib
    include Rake::DSL if defined?(Rake::DSL)

    attr_accessor :name
    attr_accessor :project
    attr_accessor :target
    attr_accessor :workspace
    attr_accessor :scheme
    attr_accessor :sdk
    attr_accessor :configuration
    attr_accessor :signing_identity
    attr_accessor :provisioning_profile
    attr_accessor :build_dir
    attr_accessor :coverage
    attr_accessor :formatter

    attr_reader :destinations
    attr_reader :provisioning_profile_name
    attr_reader :provisioning_profile_uuid

    def initialize(name)
      @name = name
      @destinations = []
      @build_settings = {}
    end

    def project
      if @project
        File.extname(@project).empty? ? "#{@project}.xcodeproj" : @project
      end
    end

    def workspace
      if @workspace
        File.extname(@workspace).empty? ? "#{@workspace}.xcworkspace" : @workspace
      end
    end

    def coverage_enabled
      @coverage
    end

    def before_action(&block)
      @before_action = block
    end

    def after_action(&block)
      @after_action = block
    end

    def provisioning_profile=(provisioning_profile)
      @provisioning_profile = provisioning_profile
      @provisioning_profile_path, @provisioning_profile_uuid, @provisioning_profile_name = XCJobs::Helper.extract_provisioning_profile(provisioning_profile)
    end

    def add_destination(destination)
      @destinations << destination
    end

    def add_build_setting(setting, value)
      @build_settings[setting] = value
    end

    private

    def run(cmd)
      @before_action.call if @before_action

      if @formatter
        puts (cmd + ['|', @formatter]).join(" ")
      else
        puts cmd.join(" ")
      end

      if @formatter
        Open3.pipeline_r(cmd, [@formatter]) do |stdout, wait_thrs|
          output = []
          while line = stdout.gets
            puts line
            output << line
          end

          status = wait_thrs.first.value
          if status.success?
            @after_action.call(output, status) if @after_action
          else
            fail "xcodebuild failed (exited with status: #{status.exitstatus})"
          end
        end
      else
        Open3.popen2e(*cmd) do |stdin, stdout_err, wait_thr|
          output = []
          while line = stdout_err.gets
            puts line
            output << line
          end

          status = wait_thr.value
          if status.success?
            @after_action.call(output, status) if @after_action
          else
            fail "xcodebuild failed (exited with status: #{status.exitstatus})"
          end
        end
      end
    end

    def options
      [].tap do |opts|
        opts.concat(['-project', project]) if project
        opts.concat(['-target', target]) if target
        opts.concat(['-workspace', workspace]) if workspace
        opts.concat(['-scheme', scheme]) if scheme
        opts.concat(['-sdk', sdk]) if sdk
        opts.concat(['-configuration', configuration]) if configuration
        opts.concat(['-enableCodeCoverage', 'YES']) if coverage_enabled
        opts.concat(['-derivedDataPath', build_dir]) if build_dir

        @destinations.each do |destination|
          opts.concat(['-destination', destination])
        end

        @build_settings.each do |setting, value|
          opts << "#{setting}=#{value}"
        end
      end
    end
  end

  class Test < Xcodebuild
    def initialize(name = :test)
      super
      yield self if block_given?
      define
    end

    def sdk
      @sdk || 'iphonesimulator'
    end

    private

    def define
      raise 'test action requires specifying a scheme' unless scheme
      raise 'cannot specify both a scheme and targets' if scheme && target

      desc 'test application'
      task @name do
        if sdk == 'iphonesimulator'
          add_build_setting('CODE_SIGN_IDENTITY', '""')
          add_build_setting('CODE_SIGNING_REQUIRED', 'NO')
        end
        if sdk == 'macosx'
          add_build_setting('CONFIGURATION_BUILD_DIR', File.expand_path(build_dir)) if build_dir
        end
        add_build_setting('CONFIGURATION_TEMP_DIR', File.join(build_dir, 'temp')) if build_dir
        add_build_setting('GCC_SYMBOLS_PRIVATE_EXTERN', 'NO')

        run(['xcodebuild', 'test'] + options)
        
        if coverage_enabled
          out, status = Open3.capture2(*(['xcodebuild', 'test'] + options + ['-showBuildSettings']))
          
          configuration_build_dir = out.lines.grep(/\bCONFIGURATION_BUILD_DIR\b/).first.split('=').last.strip
          project_temp_root = out.lines.grep(/\bPROJECT_TEMP_ROOT\b/).first.split('=').last.strip
          object_file_dir_normal = out.lines.grep(/\bOBJECT_FILE_DIR_normal\b/).first.split('=').last.strip
          current_arch = out.lines.grep(/\bCURRENT_ARCH\b/).first.split('=').last.strip
          executable_name = out.lines.grep(/\bEXECUTABLE_NAME\b/).first.split('=').last.strip
          executable_path = out.lines.grep(/\bEXECUTABLE_PATH\b/).first.split('=').last.strip
          
          if sdk.start_with 'iphone'
            target_path = File.join(File.join(object_file_dir_normal, current_arch), executable_name)
          elsif sdk == 'macosx'
            target_path = File.join(configuration_build_dir, executable_path)
          end
          
          code_coverage_dir = File.join(project_temp_root, 'CodeCoverage')
          profdata_dir = File.join(code_coverage_dir, scheme)
          profdata_path = File.join(profdata_dir, 'Coverage.profdata')
          
          gcov_file = {}
          source_path = ''
          
          cmd = ['xcrun', 'llvm-cov', 'report']
          opts = ['-instr-profile', profdata_path, target_path, '-use-color=0']
          puts (cmd + opts).join(" ")
          out, status = Open3.capture2(*(cmd + opts))
          out.lines.each do |line|
            puts line
          end
          
          cmd = ['xcrun', 'llvm-cov', 'show']
          puts (cmd + opts).join(" ")
          out, status = Open3.capture2(*(cmd + opts))
          out.lines.each do |line|
            match = /^(['"]?(?:\/[^\/]+)*['"]?):$/.match(line)
            if match.to_a.count > 0
              source_path = match.to_a[1]
              gcov_file[source_path] = []
              next
            end
            
            match = /^[ ]*([0-9]+|[ ]+)\|[ ]*([0-9]+)\|(.*)$/.match(line)
            next unless match.to_a.count == 4
            count, number, text = match.to_a[1..3]
            
            execution_count = case count.strip
                when ''
                  '-'.rjust(5)
                when '0'
                  '#####'
                else count
                end
            gcov_file[source_path] << "#{execution_count.rjust(5)}:#{number.rjust(5)}:#{text}"
          end
          
          gcov_file.each do |key, value|
            gcon_path = File.join(File.dirname(target_path), "#{File.basename(target_path)}.gcov")
            file = File::open(gcon_path, "w")
            file.puts("#{'-'.rjust(5)}:#{'0'.rjust(5)}:Source:#{key}")
            file.puts(value)
            file.flush
          end
        end
      end
    end
  end

  class Build < Xcodebuild
    def initialize(name = :build)
      super
      yield self if block_given?
      define
    end

    private

    def define
      raise 'the scheme is required when specifying build_dir' if build_dir && !scheme
      raise 'cannot specify both a scheme and targets' if scheme && target

      CLEAN.include(build_dir) if build_dir
      CLOBBER.include(build_dir) if build_dir

      desc 'build application'
      task @name do
        add_build_setting('CONFIGURATION_TEMP_DIR', File.join(build_dir, 'temp')) if build_dir
        add_build_setting('CODE_SIGN_IDENTITY', signing_identity) if signing_identity
        add_build_setting('PROVISIONING_PROFILE', provisioning_profile_uuid) if provisioning_profile_uuid

        run(['xcodebuild', 'build'] + options)
      end
    end
  end

  class Archive < Xcodebuild
    attr_accessor :archive_path

    def initialize(name = :archive)
      super
      yield self if block_given?
      define
    end

    private

    def define
      raise 'archive action requires specifying a scheme' unless scheme
      raise 'cannot specify both a scheme and targets' if scheme && target

      if build_dir
        CLEAN.include(build_dir)
        CLOBBER.include(build_dir)
      end

      desc 'make xcarchive'
      namespace :build do
        task @name do
          add_build_setting('CONFIGURATION_TEMP_DIR', File.join(build_dir, 'temp')) if build_dir
          add_build_setting('CODE_SIGN_IDENTITY', signing_identity) if signing_identity
          add_build_setting('PROVISIONING_PROFILE', provisioning_profile_uuid) if provisioning_profile_uuid

          run(['xcodebuild', 'archive'] + options)

          if build_dir && scheme
            bd = build_dir.shellescape
            s = scheme.shellescape
            sh %[(cd #{bd}; zip -ryq dSYMs.zip #{File.join("#{s}.xcarchive", "dSYMs")})]
            sh %[(cd #{bd}; zip -ryq #{s}.xcarchive.zip #{s}.xcarchive)]
          end
        end
      end
    end

    def archive_path
      @archive_path || (build_dir && scheme ? File.join(build_dir, scheme) : nil)
    end

    def options
      super.tap do |opts|
        opts.concat(['-archivePath', archive_path]) if archive_path
      end
    end
  end

  class Export < Xcodebuild
    attr_accessor :archive_path
    attr_accessor :export_format
    attr_accessor :export_path
    attr_accessor :export_provisioning_profile
    attr_accessor :export_signing_identity
    attr_accessor :export_installer_identity
    attr_accessor :export_with_original_signing_identity

    def initialize(name = :export)
      super
      yield self if block_given?
      define
    end

    def archive_path
      @archive_path || (build_dir && scheme ? File.join(build_dir, scheme) : nil)
    end

    def export_format
      @export_format || 'IPA'
    end

    def export_provisioning_profile=(provisioning_profile)
      provisioning_profile_path, provisioning_profile_uuid, provisioning_profile_name = XCJobs::Helper.extract_provisioning_profile(provisioning_profile)
      if provisioning_profile_name
        @export_provisioning_profile = provisioning_profile_name
      else
        @export_provisioning_profile = provisioning_profile
      end
    end

    private

    def define
      desc 'export from an archive'
      namespace :build do
        task name do
          run(['xcodebuild', '-exportArchive'] + options)
        end
      end
    end

    def options
      [].tap do |opts|
        opts.concat(['-archivePath', archive_path]) if archive_path
        opts.concat(['-exportFormat', export_format])  if export_format
        opts.concat(['-exportPath', export_path]) if export_path
        opts.concat(['-exportProvisioningProfile', export_provisioning_profile]) if export_provisioning_profile
        opts.concat(['-exportSigningIdentity', export_signing_identity]) if export_signing_identity
        opts.concat(['-exportInstallerIdentity', export_installer_identity]) if export_installer_identity
        opts.concat(['-exportWithOriginalSigningIdentity']) if export_with_original_signing_identity
      end
    end
  end
end
