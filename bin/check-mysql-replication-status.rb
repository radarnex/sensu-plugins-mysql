#!/usr/bin/env ruby
#
# MySQL Replication Status (modded from disk)
# ===
#
# Copyright 2011 Sonian, Inc <chefs@sonian.net>
# Updated by Oluwaseun Obajobi 2014 to accept ini argument
# Updated by Nicola Strappazzon 2016 to implement Multi Source Replication
#
# Released under the same terms as Sensu (the MIT license); see LICENSE
# for details.
#
# USING INI ARGUMENT
# This was implemented to load mysql credentials without parsing the username/password.
# The ini file should be readable by the sensu user/group.
# Ref: http://eric.lubow.org/2009/ruby/parsing-ini-files-with-ruby/
#
#   EXAMPLE
#     mysql-alive.rb -h db01 --ini '/etc/sensu/my.cnf'
#
#   MY.CNF INI FORMAT
#   [client]
#   user=sensu
#   password="abcd1234"
#

require 'sensu-plugin/check/cli'
require 'mysql'
require 'inifile'

class CheckMysqlReplicationStatus < Sensu::Plugin::Check::CLI
  option :host,
         short: '-h',
         long: '--host=VALUE',
         description: 'Database host'

  option :port,
         short: '-P',
         long: '--port=VALUE',
         description: 'Database port',
         default: 3306,
         # #YELLOW
         proc: lambda { |s| s.to_i } # rubocop:disable Lambda

  option :socket,
         short: '-s SOCKET',
         long: '--socket SOCKET',
         description: 'Socket to use'

  option :user,
         short: '-u',
         long: '--username=VALUE',
         description: 'Database username'

  option :pass,
         short: '-p',
         long: '--password=VALUE',
         description: 'Database password'

  option :master_connection,
         short: '-m',
         long: '--master-connection=VALUE',
         description: 'Replication master connection name'

  option :ini,
         short: '-i',
         long: '--ini VALUE',
         description: 'My.cnf ini file'

  option :warn,
         short: '-w',
         long: '--warning=VALUE',
         description: 'Warning threshold for replication lag',
         default: 900,
         # #YELLOW
         proc: lambda { |s| s.to_i } # rubocop:disable Lambda

  option :crit,
         short: '-c',
         long: '--critical=VALUE',
         description: 'Critical threshold for replication lag',
         default: 1800,
         # #YELLOW
         proc: lambda { |s| s.to_i } # rubocop:disable Lambda

   def credentials
     if config[:ini]
       ini = IniFile.load(config[:ini])
       section = ini['client']
       db_host = section['host']
       db_user = section['user']
       db_pass = section['password']
       db_socket = section['socket']
     else
       db_host = config[:host]
       db_user = config[:user]
       db_pass = config[:password]
       db_socket = config[:socket]
     end
     [db_host, db_user, db_pass, db_socket]
   end

  def master_connection
    master_connection = config[:master_connection]
    [master_connection]
  end

  def db_flavor
    db_flavor = nil
    db_flavor_version = db.query 'SHOW VARIABLES LIKE "version_comment"'
    db_flavor_version.each_hash do |row|
      if row['Value'].include? 'mariadb'
        db_flavor = 'mariadb'
      elsif row['Value'].include? 'MySQL'
        db_flavor = 'mysql'
      elsif row['Value'].include? 'Percona'
        db_flavor = 'percona'
      else
        db_flavor = 'unknown'
      end

    return db_flavor
  end

  def run
    db_host = credentials[0]
    db_user = credentials[1]
    db_pass = credentials[2]
    db_socket = credentials[3]

    if [db_host, db_user, db_pass].any?(&:nil?)
      unknown 'Must specify host, user, password'
    end

    db_conn = master_connection[0]

    begin
      db = Mysql.new(db_host, db_user, db_pass, nil, config[:port], config[:socket])

      flavor = db_flavor

      results = if db_conn.nil?
                  db.query 'SHOW SLAVE STATUS'
                elsif flavor.include? 'mariadb'
                  db.query "SHOW SLAVE '#{db_conn}' STATUS"
                elsif flavor.include? 'mysql' || flavor.include? 'percona'
                  db.query "SHOW SLAVE STATUS FOR CHANNEL '#{db_conn}'"
                end

      unless results.nil?
        results.each_hash do |row|
          warn "couldn't detect replication status" unless
            %w(Slave_IO_State Slave_IO_Running Slave_SQL_Running Last_IO_Error Last_SQL_Error Seconds_Behind_Master).all? do |key|
              row.key? key
            end

          slave_running = %w(Slave_IO_Running Slave_SQL_Running).all? do |key|
            row[key] =~ /Yes/
          end

          output = if db_conn.nil?
                     'Slave not running!'
                   else
                     "Slave on master connection #{db_conn} not running!"
                   end

          output += ' STATES:'
          output += " Slave_IO_Running=#{row['Slave_IO_Running']}"
          output += ", Slave_SQL_Running=#{row['Slave_SQL_Running']}"
          output += ", LAST ERROR: #{row['Last_SQL_Error']}"

          critical output unless slave_running

          replication_delay = row['Seconds_Behind_Master'].to_i

          message = "replication delayed by #{replication_delay}"

          if replication_delay > config[:warn] &&
             replication_delay <= config[:crit]
            warning message
          elsif replication_delay >= config[:crit]
            critical message
          elsif db_conn.nil?
            ok "slave running: #{slave_running}, #{message}"
          else
            ok "master connection: #{db_conn}, slave running: #{slave_running}, #{message}"
          end
        end
        ok 'show slave status was nil. This server is not a slave.'
      end

    rescue Mysql::Error => e
      errstr = "Error code: #{e.errno} Error message: #{e.error}"
      critical "#{errstr} SQLSTATE: #{e.sqlstate}" if e.respond_to?('sqlstate')

    rescue => e
      critical e

    ensure
      db.close if db
    end
  end
end
