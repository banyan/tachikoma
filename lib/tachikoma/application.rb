require 'safe_yaml'
require 'uri'
require 'tachikoma'
require 'octokit'
require 'fileutils'

module Tachikoma
  class Application
    include FileUtils

    def self.run(strategy)
      new.run(strategy)
    end

    def run(strategy)
      load
      fetch
      send(strategy) if respond_to?(strategy)
      pull_request
    end

    def load
      @build_for = ENV['BUILD_FOR']
      @github_token = ENV[github_token_key(@build_for)]

      base_config_path = File.join(Tachikoma.original_data_path, 'default.yaml')
      base_config = YAML.safe_load_file(base_config_path) || {}
      user_config_path = File.join(Tachikoma.data_path, '__user_config__.yaml')
      user_config = YAML.safe_load_file(user_config_path) if File.exist?(user_config_path)
      user_config ||= {}
      each_config_path = File.join(Tachikoma.data_path, "#{@build_for}.yaml")
      each_config = YAML.safe_load_file(each_config_path) if File.exist?(each_config_path)
      unless each_config
        fail %Q!Something wrong, BUILD_FOR: #{@build_for}, your config_path: #{each_config_path}!
      end

      @configure = base_config.merge(user_config).merge(each_config)

      @commiter_name = @configure['commiter_name']
      @commiter_email = @configure['commiter_email']
      @github_account = @configure['github_account']
      @url = @configure['url']
      @type = @configure['type']
      @base_remote_branch = @configure['base_remote_branch']
      @authorized_url = authorized_url_with_type(@url, @type, @github_token, @github_account)
      @timestamp_format = @configure['timestamp_format']
      @readable_time = Time.now.utc.strftime(@timestamp_format)
      @parallel_option = bundler_parallel_option(Bundler::VERSION, @configure['bundler_parallel_number'])

      @target_head = target_repository_user(@type, @url, @github_account)
      @pull_request_url = repository_identity(@url)
      @pull_request_body = @configure['pull_request_body']
      @pull_request_base = @configure['pull_request_base']
      @pull_request_head = "#{@target_head}:feature/bundle-#{@readable_time}"
      @pull_request_title = "Bundle update #{@readable_time}"
    end

    def clean
      mkdir_p(Tachikoma.repos_path)
      rm_rf(Dir.glob(File.join(Tachikoma.repos_path, '*')))
    end

    def fetch
      clean
      if @type == 'private'
        sh "git clone #{@authorized_url} #{Tachikoma.repos_path.to_s}/#{@build_for}"
      else
        sh "git clone #{@url} #{Tachikoma.repos_path.to_s}/#{@build_for}"
      end
    end

    def bundle
      Dir.chdir("#{Tachikoma.repos_path.to_s}/#{@build_for}") do
        Bundler.with_clean_env do
          sh %Q|ruby -i -pe '$_.gsub! /^ruby/, "#ruby"' Gemfile|
          sh "git config user.name #{@commiter_name}"
          sh "git config user.email #{@commiter_email}"
          sh "git checkout -b feature/bundle-#{@readable_time} #{@base_remote_branch}"
          sh "bundle --gemfile Gemfile --no-deployment --without nothing --path vendor/bundle #{@parallel_option}"
          sh 'bundle update'
          sh 'git add Gemfile.lock'
          sh %Q!git commit -m "Bundle update #{@readable_time}"! do; end # ignore exitstatus
          sh "git push #{@authorized_url} feature/bundle-#{@readable_time}"
        end
      end
    end

    def carton
      Dir.chdir("#{Tachikoma.repos_path.to_s}/#{@build_for}") do
        sh "git config user.name #{@commiter_name}"
        sh "git config user.email #{@commiter_email}"
        sh "git checkout -b feature/carton-#{@readable_time} #{@base_remote_branch}"
        sh 'carton install'
        sh 'carton update'
        sh 'git add carton.lock' if File.exist?('carton.lock')
        sh 'git add cpanfile.snapshot' if File.exist?('cpanfile.snapshot')
        sh %Q!git commit -m "Carton update #{@readable_time}"! do; end # ignore exitstatus
        sh "git push #{@authorized_url} feature/carton-#{@readable_time}"
      end
    end

    def pull_request
      begin
        @client = Octokit::Client.new access_token: @github_token
        @client.create_pull_request(@pull_request_url, @pull_request_base, @pull_request_head, @pull_request_title, @pull_request_body)
      rescue Octokit::UnprocessableEntity
      end
    end

    # build_for = fenix-knight, github_token_key = TOKEN_FENIX_KNIGHT
    def github_token_key(build_for)
      "TOKEN_#{build_for}".gsub(/-/, '_').upcase
    end

    def authorized_url_with_type(fetch_url, type, github_token, github_account)
      uri = URI.parse(fetch_url)
      case type
      when 'fork'
        %Q!#{uri.scheme}://#{github_token}:x-oauth-basic@#{uri.host}#{path_for_fork(uri.path, github_account)}!
      when 'shared', 'private'
        "#{uri.scheme}://#{github_token}:x-oauth-basic@#{uri.host}#{uri.path}"
      else
        raise "Invalid type #{type}"
      end
    end

    def path_for_fork(path, github_account)
      path.sub(%r!^/[^/]+!) { '/' + github_account }
    end

    def target_repository_user(type, fetch_url, github_account)
      case type
      when 'fork'
        github_account
      when 'shared', 'private'
        uri = URI.parse(fetch_url)
        uri.path.sub(%r!/([^/]+)/.*!) { $1 }
      else
        raise "Invalid type #{type}"
      end
    end

    def repository_identity(url)
      %r!((?:[^/]*?)/(?:[^/]*?))(?:\.git)?$!.match(url)[1]
    end

    def bundler_parallel_option(bundler_version, parallel_number)
      # bundler 1.4.0.pre.1 gets parallel number option
      if Gem::Version.create(bundler_version) >= Gem::Version.create('1.4.0.pre.1') && parallel_number > 1
        "--jobs=#{parallel_number}"
      end
    end
  end
end
