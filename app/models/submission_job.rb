require 'app/models/github'
require 'app/models/log_message'
require 'app/models/pod'
require 'app/models/pod_version'

module Pod
  module PushApp
    class SubmissionJob < Sequel::Model
      class TaskError < ::StandardError; end

      RETRY_COUNT = 10

      self.dataset = :submission_jobs
      plugin :timestamps

      many_to_one :pod_version
      one_to_many :log_messages

      def self.disable_info_logging
        sev_threshold = PUSH_LOGGER.sev_threshold
        PUSH_LOGGER.sev_threshold = Logger::WARN
        yield
      ensure
        PUSH_LOGGER.sev_threshold = sev_threshold
      end

      def self.find_first_job_in_queue
        disable_info_logging do
          for_update.order(Sequel.asc(:updated_at)).first(:needs_to_perform_work => true)
        end
      end

      def self.perform_task!
        if job = find_first_job_in_queue
          job.perform_next_task!
          true
        else
          false
        end
      end

      alias_method :travis_build_success?, :travis_build_success
      alias_method :needs_to_perform_work?, :needs_to_perform_work

      def in_progress?
        succeeded.nil?
      end

      def completed?
        !succeeded.nil? && succeeded
      end

      def failed?
        !succeeded.nil? && !succeeded
      end

      def after_create
        super
        add_log_message(:message => 'Submitted')
      end

      def after_update
        super
        if @columns_updated.has_key?(:succeeded) && @columns_updated[:succeeded] == true
          pod_version.update(:published => true)
        end
      end

      def pull_request_number=(number)
        super
        self.needs_to_perform_work = pull_request_number.nil?
      end

      def travis_build_success=(result)
        super
        unless travis_build_success.nil?
          self.needs_to_perform_work = travis_build_success?
          self.succeeded = false unless travis_build_success?
        end
      end

      def merge_commit_sha=(sha)
        super
        self.needs_to_perform_work = merge_commit_sha.nil?
        self.succeeded = true unless merge_commit_sha.nil?
      end

      def perform_next_task!
        unless needs_to_perform_work?
          raise TaskError, "This job is marked as not needing to perform work."
        end

        if base_commit_sha.nil?
          fetch_base_commit_sha!
        elsif base_tree_sha.nil?
          fetch_base_tree_sha!
        elsif new_tree_sha.nil?
          create_tree!
        elsif new_commit_sha.nil?
          create_commit!
        elsif new_branch_ref.nil?
          create_branch!
        elsif pull_request_number.nil?
          create_pull_request!
        elsif !travis_build_success.nil?
          merge_pull_request!
        else
          raise TaskError, "Unable to determine job state."
        end
      end

      protected

      def perform_task(message, &block)
        add_log_message(:message => message)
        begin
          self.class.db.transaction(:savepoint => true, &block)
        rescue Object => e
          if attempts == RETRY_COUNT
            update(:succeeded => false, :needs_to_perform_work => false)
          else
            update(:attempts => attempts + 1)
          end
          # TODO report full error to error reporting service
          add_log_message(:message => "Error: #{e.message}")
          PUSH_LOGGER.error "#{e.message}\n\t\t#{e.backtrace.join("\n\t\t")}"
        end
      end

      # GitHub pull-request
      #
      # TODO validate SHAs

      REPO        = ENV['GH_REPO'].dup.freeze
      BASE_BRANCH = 'master'.freeze
      BASIC_AUTH  = { :username => ENV['GH_USERNAME'], :password => ENV['GH_PASSWORD'] }.freeze

      def github
        @github ||= GitHub.new(REPO, BASE_BRANCH, BASIC_AUTH)
      end

      def fetch_base_commit_sha!
        perform_task "Fetching latest commit SHA." do
          update(:base_commit_sha => github.fetch_latest_commit_sha)
        end
      end

      def fetch_base_tree_sha!
        perform_task "Fetching tree SHA of commit #{base_commit_sha}." do
          update(:base_tree_sha => github.fetch_base_tree_sha(base_commit_sha))
        end
      end

      def create_tree!
        perform_task "Creating new tree based on tree #{base_tree_sha}." do
          destination_path = File.join(pod_version.pod.name, pod_version.name, "#{pod_version.pod.name}.podspec.yaml")
          update(:new_tree_sha => github.create_new_tree(base_tree_sha,
                                                         destination_path,
                                                         specification_data))
        end
      end

      def create_commit!
        perform_task "Creating new commit with tree #{new_tree_sha}." do
          message = "[Add] #{pod_version.pod.name} #{pod_version.name}"
          update(:new_commit_sha => github.create_new_commit(new_tree_sha,
                                                             base_commit_sha,
                                                             message))
        end
      end

      # TODO create branch name according to: https://www.kernel.org/pub/software/scm/git/docs/git-check-ref-format.html
      def create_branch!
        branch_name = "#{pod_version.pod.name}-#{pod_version.name}-job-#{self.id}"
        perform_task "Creating new branch `#{branch_name}' with commit #{new_commit_sha}." do
          update(:new_branch_ref => github.create_new_branch(branch_name,
                                                             new_commit_sha))
        end
      end

      def create_pull_request!
        perform_task "Creating new pull-request with branch #{new_branch_ref}." do
          title = "[Add] #{pod_version.pod.name} #{pod_version.name}"
          update(:pull_request_number => github.create_new_pull_request(title,
                                                                        pod_version.url,
                                                                        new_branch_ref))
        end
      end

      def merge_pull_request!
        perform_task "Merging pull-request number #{pull_request_number}" do
          update(:merge_commit_sha => github.merge_pull_request(pull_request_number))
        end
      end
    end
  end
end

