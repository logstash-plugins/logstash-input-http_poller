# encoding: utf-8
require "logstash/namespace"
require "fileutils"

module LogStash
  module Inputs
    module HTTPPoller
      class StateHandler
        def initialize(logger, requests)
          @logger = logger
          @state_path = ::File.join(LogStash::SETTINGS.get_value("path.data"), "plugins", "inputs", "http_poller", "state")
          FileUtils.mkpath @state_path
          @requests = requests
          @pages_mutex = Mutex.new
          @in_progress_pages = nil
          @pages_signal = ConditionVariable.new
          @stop_writer = false
          @state_writer_thread = nil
        end

        attr_reader :in_progress_pages

        public
        def signal_waiting_threads
          @pages_signal.broadcast
        end

        private
        def get_state_file_path(name)
          return ::File.join(@state_path, "state_" + name)
        end

        private
        def atomic_state_write(file_path, current_page)
          ::File.write(file_path + ".tmp", YAML.dump([@in_progress_pages.to_a, current_page.get]), mode: "w")
          ::File.rename(file_path + ".tmp", file_path)
        end

        public
        def write_state(name, last_run_metadata_path, current_page)
          file_path = last_run_metadata_path.nil? ? get_state_file_path(name) : last_run_metadata_path
          atomic_state_write(file_path, current_page)
        end

        private
        def start_pagination_state_writer(write_interval, name, last_run_metadata_path, current_page)
          thr = Thread.new {
            file_path = last_run_metadata_path.nil? ? get_state_file_path(name) : last_run_metadata_path
            while true do
              if @stop_writer
                break
              end
              atomic_state_write(file_path, current_page)
              sleep write_interval
            end
          }
          return thr
        end

        public
        def stop_pagination_state_writer()
          @stop_writer = true
          @state_writer_thread.join(25)
          @stop_writer = false
        end

        private
        def start_with_default_values(name, last_run_metadata_path, default_start_page, write_interval)
          @in_progress_pages = java.util.concurrent.ConcurrentSkipListSet.new
          start_page = java.util.concurrent.atomic.AtomicInteger.new(default_start_page)
          @state_writer_thread = start_pagination_state_writer(write_interval, name, last_run_metadata_path, start_page)
          return start_page, []
        end

        public
        def start_paginated_request(name, file_path, default_start_page, write_interval)
          file_path = get_state_file_path(name) if file_path.nil?
          begin
            pages, current_page = YAML.load_file(file_path)
            return start_with_default_values(name, file_path, default_start_page, write_interval) if !pages.is_a?(Array) || !current_page.is_a?(Integer)
            current_page_atomic = java.util.concurrent.atomic.AtomicInteger.new(current_page)
            @state_writer_thread = start_pagination_state_writer(write_interval, name, file_path, current_page_atomic)
            @in_progress_pages = java.util.concurrent.ConcurrentSkipListSet.new(pages)
            @logger.info? && @logger.info("Read status from file for url %s" % [name])
            return current_page_atomic, pages
          end
        rescue Errno::ENOENT, SyntaxError
          return start_with_default_values(name, file_path, default_start_page, write_interval)
        end

        public
        def add_page(name, page)
          @in_progress_pages.add(page.get)
        end

        public
        def delete_page(name, request)
          if not @in_progress_pages.nil?
            request_opts = request[2]
            page = request_opts[:query][request_opts[:pagination]["page_parameter"]]
            @in_progress_pages.remove(Integer(page))
            @pages_signal.broadcast
          end
        end

        public
        def wait_for_change(name, max_value, plugin)
          @pages_mutex.synchronize {
            while @in_progress_pages.size > max_value && !plugin.stop? do
              @pages_signal.wait(@pages_mutex)
            end
          }
        end

        public
        def delete_state(name, last_run_metadata_path)
          if not last_run_metadata_path.nil?
            ::File.delete(last_run_metadata_path)
            return
          end
          file_path = get_state_file_path(name)
          ::File.delete(file_path)
        rescue Errno::ENOENT
          # it doesn't matter if the file does not exist
        end

        def stop_paginated_request()
          @in_progress_pages = nil
        end
      end
    end
  end
end
