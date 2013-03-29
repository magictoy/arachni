=begin
    Copyright 2010-2013 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'ostruct'

module Arachni
lib = Options.dir['lib']

require lib + 'rpc/client/instance'
require lib + 'rpc/client/dispatcher'

require lib + 'rpc/server/base'
require lib + 'rpc/server/active_options'
require lib + 'rpc/server/output'
require lib + 'rpc/server/framework'

module RPC
class Server

#
# Represents an Arachni instance (or multiple instances when running a
# high-performance scan) and serves as a central point of access to the
# scanner's components:
#
# * {Instance self} -- mapped to `service`
# * {Options} -- mapped to `opts`
# * {Framework} -- mapped to `framework`
# * {Module::Manager} -- mapped to `modules`
# * {Plugin::Manager} -- mapped to `plugins`
# * {Spider} -- mapped to `spider`
#
# It also provides convenience methods for:
#
# * {#scan Configuring and running a scan}
# * Retrieving progress information
#   * {#progress in aggregate form} (which includes a multitude of information)
#   * or simply by:
#       * {#busy? checking whether the scan is still in progress}
#       * {#status checking the status of the scan}
# * {#pause Pausing}, {#resume resuming} or {#abort_and_report aborting} the scan.
# * Retrieving the scan report
#   * {#report as a Hash} or a native {#auditstore AuditStore} object
#   * {#report_as in one of the supported formats} (as made available by the
#     {Reports report} components)
# * {#shutdown Shutting down}
#
# The above operations should be enough to cover your needs so you needn't
# concern yourself with the more specialized components of the system.
#
# (A nice simple example can be found in the {UI::CLI::RPC RPC command-line client}
# interface.)
#
# @example A minimalistic example -- assumes Arachni is installed and available.
#    require 'arachni'
#    require 'arachni/rpc/client'
#
#    instance = Arachni::RPC::Client::Instance.new( Options.instance, 'localhost:1111', 's3cr3t' )
#
#    instance.service.scan url: 'http://testfire.net',
#                          audit_links: true,
#                          audit_forms: true,
#                          # load all XSS modules
#                          modules: 'xss*'
#
#    print 'Running.'
#    while instance.service.busy?
#        print '.'
#        sleep 1
#    end
#
#    # Grab the report as a native AuditStore object
#    report = instance.service.auditstore
#
#    # Kill the instance and its process, no zombies please...
#    instance.service.shutdown
#
#    puts
#    puts
#    puts 'Logged issues:'
#    report.issues.each do |issue|
#        puts "  * #{issue.name} for input '#{issue.var}' at '#{issue.url}'."
#    end
#
# @note Ignore:
#
#   * Inherited methods and attributes -- only public methods of this class are
#       accessible over RPC.
#   * `block` parameters, they are an RPC implementation detail for methods which
#       perform asynchronous operations.
#
# @note Avoid calling methods which return Arachni-specific objects (like {AuditStore},
#   {Issue}, etc.) when you don't have these objects available on the client-side
#   (like when working from a non-Ruby platform or not having the Arachni framework
#   installed).
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Instance
    include UI::Output
    include Utilities

    private :error_logfile
    public  :error_logfile

    #
    # Initializes the RPC interface and the framework.
    #
    # @param    [Options]    opts
    # @param    [String]    token   Authentication token.
    #
    def initialize( opts, token )
        banner

        @opts   = opts
        @token  = token

        @server = Base.new( @opts, token )

        @server.logger.level = @opts.datastore[:log_level] if @opts.datastore[:log_level]

        @opts.datastore[:token] = token

        debug if @opts.debug

        if @opts.reroute_to_logfile
            reroute_to_file "#{@opts.dir['logs']}/Instance - #{Process.pid}-#{@opts.rpc_port}.log"
        else
            reroute_to_file false
        end

        set_error_logfile "#{@opts.dir['logs']}/Instance - #{Process.pid}-#{@opts.rpc_port}.error.log"

        set_handlers

        # trap interrupts and exit cleanly when required
        %w(QUIT INT).each do |signal|
            trap( signal ){ shutdown } if Signal.list.has_key?( signal )
        end

        run
    end

    # @return   [true]
    def alive?
        @server.alive?
    end

    # @return   [Bool]
    #   `true` if the scan is initializing or running, `false` otherwise.
    #   If a scan is started by {#scan} then this method should be used
    #   instead of {Framework#busy?}.
    def busy?
        @scan_initializing ? true : @framework.busy?
    end

    # @param (see Arachni::RPC::Server::Framework#errors)
    # @return (see Arachni::RPC::Server::Framework#errors)
    def errors( starting_line = 0, &block )
        @framework.errors( starting_line, &block )
    end

    #
    # Pauses the running scan on a best effort basis.
    #
    # @see Framework#pause
    def pause( &block )
        @framework.pause( &block )
    end

    #
    # Resumes a paused scan.
    #
    # @see Framework#resume
    def resume( &block )
        @framework.resume( &block )
    end

    #
    # Cleans up and returns the report.
    #
    # @param   [Symbol] report_type
    #   Report type to return, `:hash` for {#report} or `:audistore` for
    #   {#auditstore}.
    #
    # @return  [Hash,AuditStore]
    #
    # @note Don't forget to {#shutdown} the instance once you get the report.
    #
    # @see Framework#clean_up
    # @see #abort_and_report
    # @see #report
    # @see #auditstore
    #
    def abort_and_report( report_type = :hash, &block )
        @framework.clean_up do
            block.call report_type == :auditstore ? auditstore : report
        end
    end

    #
    # Cleans up and delegates to {#report_as}.
    #
    # @param (see #report_as)
    # @return (see #report_as)
    #
    # @note Don't forget to {#shutdown} the instance once you get the report.
    #
    # @see Framework#clean_up
    # @see #abort_and_report
    # @see #report_as
    #
    def abort_and_report_as( name, &block )
        @framework.clean_up do
            block.call report_as( name )
        end
    end

    # @return (see Arachni::Framework#auditstore)
    # @see Framework#auditstore
    def auditstore
        @framework.auditstore
    end

    # @return (see Arachni::RPC::Server::Framework#report)
    # @see Framework#report
    def report
        @framework.report
    end

    # @param    [String]    name
    #   Name of the report component to run as presented by
    #   {Framework#list_reports} `:rep_name` key.
    #
    # @return (see Arachni::Framework#report_as)
    # @see Framework#report_as
    def report_as( name )
        @framework.report_as( name )
    end

    # @see Framework#status
    def status
        @framework.status
    end

    #
    # Simplified version of {Framework#progress}.
    #
    # Returns the following information:
    #
    # * `stats` -- General runtime statistics (merged when part of Grid)
    #   (enabled by default)
    # * `status` -- {#status}
    # * `busy` -- {#busy?}
    # * `issues` -- {Framework#issues_as_hash} or {Framework#issues}
    #   (disabled by default)
    # * `instances` -- Raw `stats` for each running instance (only when part
    #   of Grid) (disabled by default)
    # * `errors` -- {#errors} (disabled by default)
    #
    # @param  [Hash]  options
    #   Options about what progress data to retrieve and return.
    # @option options [Array<Symbol, Hash>]  :with
    #   Specify data to include:
    #
    #   * :native_issues -- Discovered issues as {Arachni::Issue} objects.
    #   * :issues -- Discovered issues as {Arachni::Issue#to_h hashes}.
    #   * :instances -- Statistics and info for slave instances.
    #   * :errors -- Errors and the line offset to use for {#errors}.
    #     Pass as a hash, like: `{ errors: 10 }`
    # @option options [Array<Symbol, Hash>]  :without
    #   Specify data to exclude:
    #
    #   * :stats -- Don't include runtime statistics.
    #   * :issues -- Don't include issues with the given {Arachni::Issue#digest digests}.
    #     Pass as a hash, like: `{ issues: [...] }`
    #
    def progress( options = {}, &block )
        with    = parse_progress_opts( options, :with )
        without = parse_progress_opts( options, :without )

        @framework.progress( as_hash:   !with.include?( :native_issues ),
                             issues:    with.include?( :native_issues ) || with.include?( :issues ),
                             stats:     !without.include?( :stats ),
                             slaves:    with.include?( :instances ),
                             messages:  false,
                             errors:    with[:errors]
        ) do |data|
            data['instances'] ||= [] if with.include?( :instances )
            data['busy'] = busy?

            if data['issues']
                data['issues'] = data['issues'].dup

                if without[:issues].is_a? Array
                    data['issues'].reject! do |i|
                        without[:issues].include?( i.is_a?( Hash ) ? i['digest'] : i.digest )
                    end
                end
            end

            block.call( data )
        end
    end

    #
    # Configures and runs a scan.
    #
    # @note If you use this method to start the scan use {#busy?} instead of
    #   {Framework#busy?} to check if the scan is still running.
    #
    # @note Options marked with an asterisk are required.
    # @note Options which expect patterns will interpret their arguments as
    #   regular expressions regardless of their type.
    #
    # @param  [Hash]  opts
    #   Scan options to be passed to {Options#set}, along with some extra ones
    #   to makes things simpler.
    #   The options presented here are the most common ones, you can use any
    #   {Options} attribute.
    # @option opts [String]  *:url
    #   Target URL to audit.
    # @option opts [Boolean] :audit_links (false)
    #   Enable auditing of link inputs.
    # @option opts [Boolean] :audit_forms (false)
    #   Enable auditing of form inputs.
    # @option opts [Boolean] :audit_cookies (false)
    #   Enable auditing of cookie inputs.
    # @option opts [Boolean] :audit_headers (false)
    #   Enable auditing of header inputs.
    # @option opts [String,Array<String>] :modules ([])
    #   Modules to load, by name.
    #
    #       # To load all modules use the wildcard on its own
    #       '*'
    #
    #       # To load all XSS and SQLi modules:
    #       [ 'xss*', 'sqli*' ]
    #
    # @option opts [Hash<Hash>] :plugins ({})
    #   Plugins to load, by name, along with their options.
    #
    #       {
    #           'proxy'      => {}, # empty options
    #           'autologin'  => {
    #               'url'    => 'http://demo.testfire.net/bank/login.aspx',
    #               'params' => 'uid=jsmith&passw=Demo1234',
    #               'check'  => 'MY ACCOUNT'
    #           },
    #       }
    # @option opts [Integer] :link_count_limit (nil)
    #   Limit the amount of pages to be crawled and audited.
    # @option opts [Array<String, Regexp>] :exclude ([])
    #   URLs that match any of the given patterns will be ignored.
    #
    #       [ 'logout', /skip.*.me too/i ]
    #
    # @option opts [Array<String, Regexp>] :exclude_pages ([])
    #   Exclude pages from the crawl and audit processes based on their
    #   content (i.e. HTTP response bodies).
    #
    #       [ /.*forbidden.*/, "I'm a weird 404 and I should be ignored" ]
    #
    # @option opts [Array<String>] :exclude_vectors ([])
    #   Exclude input vectors from the audit, by name.
    #
    #       [ 'sessionid', 'please_dont_audit_me' ]
    #
    # @option opts [Array<String, Regexp>] :include ([])
    #   Only URLs that match any of the given patterns will be followed and audited.
    #
    #       [ 'only-follow-me', 'follow-me-as-well' ]
    #
    # @option opts [Hash<<String, Regexp>,Integer>] :redundant ({})
    #   Redundancy patterns to limit how many times certain paths should be
    #   followed. Useful when scanning pages that create an large number of
    #   pages like galleries and calendars.
    #
    #       { "follow_me_3_times" => 3, /follow_me_5_times/ => 5 }
    #
    # @option opts [Hash<String, String>] :cookies ({})
    #   Cookies to use for the HTTP requests.
    #
    #       {
    #           'userid' => '1',
    #           'sessionid' => 'fdfdfDDfsdfszdf'
    #       }
    #
    # @option opts [Integer] :http_req_limit (20)
    #   HTTP request concurrency limit.
    # @option opts [String] :user_agent ('Arachni/v<version>')
    #   User agent to use.
    # @option opts [String] :authed_by (nil)
    #   The person who authorized the scan.
    #
    #       John Doe <john.doe@bigscanners.com>
    #
    # @option opts [Array<Hash>]  :slaves   **(Experimental)**
    #   Info of Instances to {Framework#enslave enslave}.
    #
    #       [
    #           { 'url' => 'address:port', 'token' => 's3cr3t' },
    #           { 'url' => 'anotheraddress:port', 'token' => 'e3nm0r3s3cr3t' }
    #       ]
    #
    # @option opts [Bool]  :grid    (false) **(Experimental)**
    #   Utilise the Dispatcher Grid to obtain slave instances for a
    #   high-performance distributed scan.
    # @option opts [Integer]  :spawns   (0) **(Experimental)**
    #   The amount of slaves to spawn.
    # @option opts [Array<Page>]  :pages    ([])    **(Experimental)**
    #   Extra pages to audit.
    # @option opts [Array<String>]  :elements   ([])    **(Experimental)**
    #   Elements to which to restrict the audit (using elements IDs as returned
    #   by {Element::Capabilities::Auditable#scope_audit_id}).
    #
    def scan( opts = {}, &block )
        # if the instance isn't clean bail out now
        if @scan_initializing || @framework.busy?
            block.call false
            return false
        end

        # Normalize this sucker to have symbols as keys
        opts = opts.to_hash.inject( {} ) { |h, (k, v)| h[k.to_sym] = v; h }

        slaves      = opts[:slaves] || []
        spawn_count = opts[:spawns].to_i

        if opts[:grid] && spawn_count <= 0
            fail ArgumentError,
                 'Option \'spawns\' must be greater than 1 for Grid scans.'
        end

        if (opts[:grid] || spawn_count > 0) && [opts[:restrict_paths]].flatten.compact.any?
            fail ArgumentError,
                 'Option \'restrict_paths\' is not supported when in High-Performance mode.'
        end

        # There may be follow-up/retry calls by the client in cases of network
        # errors (after the request has reached us) so we need to keep minimal
        # track of state in order to bail out on subsequent calls.
        @scan_initializing = true

        # Plugins option needs to be a hash...
        if opts[:plugins] && opts[:plugins].is_a?( Array )
            opts[:plugins] = opts[:plugins].inject( {} ) { |h, n| h[n] = {}; h }
        end

        @framework.opts.set( opts )

        if @framework.opts.url.to_s.empty?
            fail ArgumentError, 'Option \'url\' is mandatory.'
        end

        @framework.update_page_queue( opts[:pages] || [] )
        @framework.restrict_to_elements( opts[:elements] || [] )

        opts[:modules] ||= opts[:mods]
        @framework.modules.load opts[:modules] if opts[:modules]
        @framework.plugins.load opts[:plugins] if opts[:plugins]

        # If the Dispatchers are in a Grid config but the user has not requested
        # a Grid scan force the framework to ignore the Grid and work with
        # the instances we give it.
        @framework.ignore_grid if has_dispatcher? && !opts[:grid]

        # Starts the scan after all necessary options have been set.
        after = proc { block.call @framework.run; @scan_initializing = false }

        if opts[:grid]
            #
            # If a Grid scan has been selected then just set us as the master
            # and set the spawn count as max slaves.
            #
            # The Framework and the Grid will sort out the rest...
            #
            @framework.set_as_master
            @framework.opts.max_slaves = spawn_count

            # Rock n' roll!
            after.call
        else
            # Handles each spawn, enslaving it for a high-performance distributed scan.
            each  = proc { |slave, iter| @framework.enslave( slave ){ iter.next } }

            spawn( spawn_count ) do |spawns|
                # Add our spawns to the slaves list which was passed as an option.
                slaves |= spawns

                # Process the Instances.
                ::EM::Iterator.new( slaves, slaves.empty? ? 1 : slaves.size ).
                    each( each, after )
            end
        end

        true
    end

    # Makes the server go bye-bye...Lights out!
    def shutdown
        print_status 'Shutting down...'

        t = []
        @framework.instance_eval do
            @instances.each do |instance|
                # Don't know why but this works better than EM's stuff
                t << Thread.new { connect_to_instance( instance ).service.shutdown! }
            end
        end
        t.join

        @server.shutdown
        true
    end
    alias :shutdown! :shutdown

    # @param (see Arachni::RPC::Server::Framework#auditstore)
    # @return (see Arachni::RPC::Server::Framework#auditstore)
    #
    # @deprecated
    def output( &block )
        @framework.output( &block )
    end

    # @private
    def error_test( str )
        print_error str.to_s
    end

    private

    def parse_progress_opts( options, key )
        parsed = {}
        [options.delete( key ) || options.delete( key.to_s )].compact.each do |w|
            case w
                when Array
                    w.compact.flatten.each do |q|
                        case q
                            when String, Symbol
                                parsed[q.to_sym] = nil
                            when Hash
                                parsed.merge!( q )
                        end
                    end

                when String, Symbol
                    parsed[w.to_sym] = nil

                when Hash
                    parsed.merge!( w )
            end
        end

        parsed
    end

    def spawn( num, &block )
        if num <= 0
            block.call []
            return
        end

        q = ::EM::Queue.new

        if has_dispatcher?
            num.times do
                dispatcher.dispatch( @framework.self_url ) do |instance|
                    q << instance
                end
            end
        else
            num.times do
                port  = available_port
                token = generate_token

                Process.detach ::EM.fork_reactor {
                    # make sure we start with a clean env (namepsace, opts, etc)
                    Framework.reset

                    Options.rpc_port = port
                    Server::Instance.new( Options.instance, token )
                }

                instance_info = { 'url' => "#{Options.rpc_address}:#{port}",
                                  'token' => token }

                wait_till_alive( instance_info ) { q << instance_info }
            end
        end

        spawns = []
        num.times do
            q.pop do |r|
                spawns << r
                block.call( spawns ) if spawns.size == num
            end
        end
    end

    def wait_till_alive( instance_info, &block )
        opts = ::OpenStruct.new

        # if after 100 retries we still haven't managed to get through give up
        opts.max_retries = 100
        opts.ssl_ca      = @opts.ssl_ca,
        opts.ssl_pkey    = @opts.node_ssl_pkey || @opts.ssl_pkey,
        opts.ssl_cert    = @opts.node_ssl_cert || @opts.ssl_cert

        Client::Instance.new(
            opts, instance_info['url'], instance_info['token']
        ).service.alive? do |alive|
            if alive.rpc_exception?
                raise alive
            else
                block.call alive
            end
        end
    end

    #
    # Starts the HTTPS server and the RPC service.
    #
    def run
        print_status 'Starting the server...'
        @server.run
    end

    def dispatcher
        @dispatcher ||=
            Client::Dispatcher.new( @opts, @opts.datastore[:dispatcher_url] )
    end

    def has_dispatcher?
        !!@opts.datastore[:dispatcher_url]
    end

    #
    # Outputs the Arachni banner.
    #
    # Displays version number, revision number, author details etc.
    #
    def banner
        puts BANNER
        puts
        puts
    end

    # Prepares all the RPC handlers.
    def set_handlers
        @server.add_async_check do |method|
            # methods that expect a block are async
            method.parameters.flatten.include?( :block )
        end

        @framework = Server::Framework.new( Options.instance )

        @server.add_handler( 'service',   self )
        @server.add_handler( 'framework', @framework )
        @server.add_handler( "opts",      Server::ActiveOptions.new( @framework ) )
        @server.add_handler( 'spider',    @framework.spider )
        @server.add_handler( 'modules',   @framework.modules )
        @server.add_handler( 'plugins',   @framework.plugins )
    end

end

end
end
end
