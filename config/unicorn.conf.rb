# Sample verbose configuration file for Unicorn (not Rack)
#
# This configuration file documents many features of Unicorn
# that may not be needed for some applications. See
# http://unicorn.bogomips.org/examples/unicorn.conf.minimal.rb
# for a much simpler configuration file.
#
# See http://unicorn.bogomips.org/Unicorn/Configurator.html for complete
# documentation.

$: << File.expand_path(File.join(File.dirname(__FILE__), "..", "lib"))

require 'rubygems'
require 'bundler/setup'
require 'workflow_server/config'

app_root = WorkflowServer::Config.root

# Use at least one worker per core if you're on a dedicated server,
# more will usually help for _short_ waits on databases/caches.
worker_processes (WorkflowServer::Config.environment == :production ? 32 : 4)

shared_root = if WorkflowServer::Config.environment == :development
                File.expand_path(File.join(app_root, "shared"))
              else
                File.expand_path(File.join(app_root, "..", "shared")) # Get out of the current directory
              end

# # Since Unicorn is never exposed to outside clients, it does not need to
# # run on the standard HTTP port (80), there is no reason to start Unicorn
# # as root unless it's from system init scripts.
# # If running the master process as root and the workers as an unprivileged
# # user, do this to switch euid/egid in the workers (also chowns logs):
# # user "unprivileged_user", "unprivileged_group"
# 
# # Help ensure your application will always spawn in the symlinked
# # "current" directory that Capistrano sets up.
working_directory app_root # available in 0.94.0+

# 
# # listen on both a Unix domain socket and a TCP port,
# # we use a shorter backlog for quicker failover when busy
system("mkdir -p #{shared_root}/sockets")
listen "#{shared_root}/sockets/unicorn.sock", :backlog => 64
listen 9000, :tcp_nopush => true
# 
# # nuke workers after 30 seconds instead of 60 seconds (the default)
timeout 30
# 
# # feel free to point this anywhere accessible on the filesystem
system("mkdir -p #{shared_root}/pids")
pid "#{shared_root}/pids/unicorn.pid"

# 
# # By default, the Unicorn logger will write to stderr.
# # Additionally, ome applications/frameworks log to stderr or stdout,
# # so prevent them from going to /dev/null when daemonized here:
system("mkdir -p #{shared_root}/log")
stderr_path "#{shared_root}/log/unicorn.stderr.log"
stdout_path "#{shared_root}/log/unicorn.stdout.log"

# 
# # combine Ruby 2.0.0dev or REE with "preload_app true" for memory savings
# # http://rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
preload_app true

# GC.respond_to?(:copy_on_write_friendly=) and
#   GC.copy_on_write_friendly = true
# 
# # Enable this flag to have unicorn test client connections by writing the
# # beginning of the HTTP headers before calling the application.  This
# # prevents calling the application for connections that have disconnected
# # while queued.  This is only guaranteed to detect clients on the same
# # host unicorn runs on, and unlikely to detect disconnects even on a
# # fast LAN.
# check_client_connection false
# 
before_fork do |server, worker|
  # by default, BUNDLE_GEMFILE is a fully resolved path (e.g., /var/groupon/backbeat/releases/20111202202204/Gemfile)
  # since Unicorn forks/execs, the new process gets the parent environment, which means we never pick up a new Gemfile
  # (and even worse, eventually, the Gemfile ceases to exist after 10 releases (we purge after 10 releases).
  begin
    ENV['BUNDLE_GEMFILE'] = File.join(File.readlink(app_root), 'Gemfile')

    $stdout.puts "I, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] INFO -- : setting BUNDLE_GEMFILE to #{ENV['BUNDLE_GEMFILE']}"
  rescue Errno::EINVAL
    $stdout.puts "E, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] ERROR -- : Unable to set BUNDLE_GEMFILE (/var/groupon/backbeat/current symlink doesn't exist?), defaulting to /var/groupon/backbeat/current/Gemfile"
    ENV['BUNDLE_GEMFILE'] = "/var/groupon/backbeat/current/Gemfile"
  end

#   # The following is only recommended for memory/DB-constrained
#   # installations.  It is not needed if your system can house
#   # twice as many worker_processes as you have configured.
#   #
#   # # This allows a new master process to incrementally
#   # # phase out the old master process with SIGTTOU to avoid a
#   # # thundering herd (especially in the "preload_app false" case)
#   # # when doing a transparent upgrade.  The last worker spawned
#   # # will then kill off the old master process with a SIGQUIT.
  pidfile = "#{shared_root}/pids/unicorn.pid"
  old_pid = pidfile + '.oldbin'
  if File.exists?(old_pid) && server.pid != old_pid
    begin
      Process.kill("QUIT", File.read(old_pid).to_i)
    rescue Errno::ENOENT, Errno::ESRCH
      # someone else did our job for us
    end
  end
#   #
#   # Throttle the master from forking too quickly by sleeping.  Due
#   # to the implementation of standard Unix signal handlers, this
#   # helps (but does not completely) prevent identical, repeated signals
#   # from being lost when the receiving process is busy.
#   # sleep 1
end

after_fork do |server, worker|
  begin
    ENV['BUNDLE_GEMFILE'] = File.join(File.readlink(app_root), 'Gemfile')

    $stdout.puts "I, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] INFO -- : setting BUNDLE_GEMFILE to #{ENV['BUNDLE_GEMFILE']}"
  rescue Errno::EINVAL
    $stdout.puts "E, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] ERROR -- : Unable to set BUNDLE_GEMFILE (/var/groupon/backbeat/current symlink doesn't exist?), defaulting to /var/groupon/backbeat/current/Gemfile"
    ENV['BUNDLE_GEMFILE'] = "/var/groupon/backbeat/current/Gemfile" 
  end

    $stdout.puts "Env is #{WorkflowServer::Config.environment}. Root is #{WorkflowServer::Config.root}"

   require 'mongoid'
   mongo_path = File.expand_path(File.join(app_root, "config", "mongoid.yml"))
   Mongoid.load!(mongo_path, WorkflowServer::Config.environment)

#   # per-process listener ports for debugging/admin/migrations
#   # addr = "127.0.0.1:#{9293 + worker.nr}"
#   # server.listen(addr, :tries => -1, :delay => 5, :tcp_nopush => true)

#   # if preload_app is true, then you may also want to check and
#   # restart any other shared sockets/descriptors such as Memcached,
#   # and Redis.  TokyoCabinet file handles are safe to reuse
#   # between any number of forked children (assuming your kernel
#   # correctly implements pread()/pwrite() system calls)
end

before_exec do |server|
  # by default, BUNDLE_GEMFILE is a fully resolved path (e.g., /data/accounting_service/releases/20111202202204/Gemfile)
  # since Unicorn forks/execs, the new process gets the parent environment, which means we never pick up a new Gemfile
  # (and even worse, eventually, the Gemfile ceases to exist after 10 releases (we purge after 10 releases).
  # Recommended here http://unicorn.bogomips.org/Sandbox.html
  begin
    ENV['BUNDLE_GEMFILE'] = File.join(File.readlink(app_root), 'Gemfile')

    # Hack to ensure we have indexes
    Dir.glob(File.join(WorkflowServer::Config.root, "lib", "workflow_server", "models", "**", "*.rb")).map do |file|
      begin
        model = "WorkflowServer::Models::#{file.match(/.+\/(?<model>.*).rb$/)['model'].camelize}"
        klass = model.constantize
        klass.create_indexes
        $stdout.puts "I, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] INFO -- : created indexes for class #{klass}"
      rescue NameError, LoadError
        $stdout.puts "I, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] ERROR -- : failed to create index for file #{file}"
      end
    end

    $stdout.puts "I, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] INFO -- : setting BUNDLE_GEMFILE to #{ENV['BUNDLE_GEMFILE']}"
  rescue Errno::EINVAL
    $stdout.puts "E, [#{Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")} \##{$$}] ERROR -- : Unable to set BUNDLE_GEMFILE (/var/groupon/backbeat/current symlink doesn't exist?), defaulting to /var/groupon/backbeat/current/Gemfile"
    ENV['BUNDLE_GEMFILE'] = "/var/groupon/backbeat/current/Gemfile"
  end
end