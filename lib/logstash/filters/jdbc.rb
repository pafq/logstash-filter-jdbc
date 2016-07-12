# encoding: utf-8
require "logstash/filters/base"
require "logstash/namespace"
require "logstash/plugin_mixins/jdbc"
require "logstash/plugin_mixins/jdbcConnection"
require "logstash/filters/statement"

# This plugin was created as a way to ingest data in any database
# with a JDBC interface into Logstash. You can periodically schedule ingestion
# using a cron syntax (see `schedule` setting) or run the query one time to load
# data into Logstash. Each row in the resultset becomes a single event.
# Columns in the resultset are converted into fields in the event.
#
# ==== Drivers
#
# This plugin does not come packaged with JDBC driver libraries. The desired
# jdbc driver library must be explicitly passed in to the plugin using the
# `jdbc_driver_library` configuration option.
#
# ==== Scheduling
#
# Input from this plugin can be scheduled to run periodically according to a specific
# schedule. This scheduling syntax is powered by https://github.com/jmettraux/rufus-scheduler[rufus-scheduler].
# The syntax is cron-like with some extensions specific to Rufus (e.g. timezone support ).
#
# Examples:
#
# |==========================================================
# | `* 5 * 1-3 *`               | will execute every minute of 5am every day of January through March.
# | `0 * * * *`                 | will execute on the 0th minute of every hour every day.
# | `0 6 * * * America/Chicago` | will execute at 6:00am (UTC/GMT -5) every day.
# |==========================================================
#
#
# Further documentation describing this syntax can be found https://github.com/jmettraux/rufus-scheduler#parsing-cronlines-and-time-strings[here].
#
# ==== Dealing With Large Result-sets
#
# Many JDBC drivers use the `fetch_size` parameter to limit how many
# results are pre-fetched at a time from the cursor into the client's cache
# before retrieving more results from the result-set. This is configured in
# this plugin using the `jdbc_fetch_size` configuration option. No fetch size
# is set by default in this plugin, so the specific driver's default size will
# be used.
#
# ==== Usage:
#
# Here is an example of setting up the plugin to fetch data from a MySQL database.
# First, we place the appropriate JDBC driver library in our current
# path (this can be placed anywhere on your filesystem). In this example, we connect to
# the 'mydb' database using the user: 'mysql' and wish to input all rows in the 'songs'
# table that match a specific artist. The following examples demonstrates a possible
# Logstash configuration for this. The `schedule` option in this example will
# instruct the plugin to execute this input statement on the minute, every minute.
#
# [source,ruby]
# ----------------------------------
# filter {
#   jdbc {
#     connection => {
#       jdbc_driver_library    => "mysql-connector-java-5.1.36-bin.jar"
#       jdbc_driver_class      => "com.mysql.jdbc.Driver"
#       jdbc_connection_string => "jdbc:mysql://localhost:3306/mydb"
#       jdbc_user              => "mysql"
#     }
#
#     statements => [
#                     {
#                       query      => "SELECT * from songs where artist = :favorite_artist"
#                       parameters => { "favorite_artist" => "Beethoven" }
#                     }
#                   ]
#   }
# }
# ----------------------------------
#
# ==== Configuring SQL statement
#
# A sql statement is required for this input. This can be passed-in via a
# query option in the form of a string, or read from a file (`file.path`). File
# option is typically used when the SQL statement is large or cumbersome to supply in the config.
# The file option only supports one SQL statement. The plugin will only accept one of the options.
# It cannot read a statement from a file as well as from the `statement` configuration parameter.
#
# ==== Predefined Parameters
#
# Some parameters are built-in and can be used from within your queries.
# Here is the list:
#
# |==========================================================
# |sql_last_start | The last time a statement was executed. This is set to Thursday, 1 January 1970
#  before any query is run, and updated accordingly after first query is run.
# |==========================================================
#
# It's possivel to configure another parameters to be store and used within your queries.
# To do that, parameters `persistence_data` must be provided with the list of fields to Store.
#
class LogStash::Filters::Jdbc < LogStash::Filters::Base
  include LogStash::PluginMixins::Jdbc
  config_name "jdbc"

  # Connection Settings
  #
  # This Settings will be used to connect to the Database to run the provide query.
  # For example:
  #
  # [source, ruby]
  # ----------------------------------
  # connection => {
  #                 jdbc_driver_library      => "mysql-connector-java-5.1.36-bin.jar"
  #                 jdbc_driver_class        => "com.mysql.jdbc.Driver"
  #                 jdbc_connection_string   => "jdbc:mysql://localhost:3306/mydb"
  #                 jdbc_user                => "mysql"
  #                 jdbc_password            => ""
  #                 jdbc_paging_enabled      => ""
  #                 jdbc_page_size           => ""
  #                 jdbc_fetch_size          => ""
  #                 jdbc_validate_connection => ""
  #                 jdbc_validation_timeout  => ""
  #              }
  # ----------------------------------
  #
  # Required Parameters
  #
  #   jdbc_driver_library = JDBC driver library path to third party driver library.
  #   jdbc_driver_class = JDBC driver class to load, for example "oracle.jdbc.OracleDriver" or "org.apache.derby.jdbc.ClientDriver"
  #   jdbc_connection_string = JDBC connection string
  #   jdbc_user = JDBC user
  #
  # Options Parameters and Default Values
  #
  #   jdbc_password = JDBC password
  #
  #   JDBC enable paging
  #
  #     This will cause a sql statement to be broken up into multiple queries.
  #     Each query will use limits and offsets to collectively retrieve the full
  #     result-set. The limit size is set with `jdbc_page_size`.
  #
  #     Be aware that ordering is not guaranteed between queries.
  #
  #     jdbc_paging_enabled = Enable Paging (default => false)
  #     jdbc_page_size = Page Size (default => 100000)
  #     jdbc_fetch_size = Fetch size. If not provided, respective driver's default will be used
  #
  #
  #   Connection pool configuration.
  #
  #      jdbc_validate_connection = Validate connection before use. (default => false)
  #      jdbc_validation_timeout = How often to validate a connection (in seconds) (default => 3600)
  config :connection, :validate => :hash

  # Statement to execute
  #
  # [source, ruby]
  # ----------------------------------
  # statements => [
  #                 {
  #                   query          => "SELECT * from songs where artist = :favorite_artist"
  #                   query_filepath => ""
  #                   parameters     => { "favorite_artist" => "Beethoven" }
  #                   node_name      => "Songs"
  #                   statement      => [
  #                                       {
  #                                         query          => "Select * from songs_albuns where song_id = :song_id"
  #                                         query_filepath => ""
  #                                         parameters     => { "favorite_artist" => "Beethoven" }
  #                                         join_keys      => [ "song_id" ]
  #                                         node_name      => "Albuns"
  #                                         statement      => { ... }
  #                                       }
  #                                     ]
  #                 }
  #               ]
  # ----------------------------------
  #
  # To use parameters, use named parameter syntax.
  # For example:
  #
  # [source, ruby]
  # ----------------------------------
  # "SELECT * FROM MYTABLE WHERE id = :target_id"
  # ----------------------------------
  #
  # here, ":target_id" is a named parameter. You can configure named parameters
  # with the `parameters` setting.
  # Whether the previous run state should be preserved
  config :statements, :validate => :array

  public
  def register
    # Add instance variables
    @jdbcConn = LogStash::PluginMixins::JdbcConnection.new
    @jdbcConn.populate(@connection)

    @stmts = []
    @statements.each do |stmt|
      stmt_obj = LogStash::Filters::Statement.new
      stmt_obj.populate(stmt)
      @stmts.push(stmt_obj)
    end

    prepare_jdbc_connection(@jdbcConn)

  end # def register

  public
  def filter(event)

#    if @message
#      # Replace the event message with our message as configured in the
#      # config file.
#      event["message"] = @message
#    end

    @stmts.each do |stmt|
      join_keys = {}
      stmt.join_keys.each do |key|
        join_keys[key] = event[key] if !event[key].nil?
      end

      execute_query(stmt, join_keys).each do |key, value|
        event[key] = value
      end

    end

    # filter_matched should go in the last line of our successful code
    filter_matched(event)
  end # def filter

  def execute_query(stmt, join_keys)
    new_nodes = {}
    stmt.parameters = {} if stmt.parameters.nil?

    #Execute Query With Current Values
    if !join_keys.nil?
      query_parameters = stmt.parameters.merge(join_keys)
    else
      query_parameters = stmt.parameters
    end

    execute_statement(@jdbcConn, stmt.query, query_parameters) do |row|

      #Verify if exists a SubQuery
      if !stmt.statement.nil?

        stmt.statement.each do |sub_stmt|
          new_join_keys = {}

          if !sub_stmt.join_keys.nil?
            sub_stmt.join_keys.each do |key|
              new_join_keys[key] = row[key] if !row[key].nil?
            end
          end

          execute_query(sub_stmt, new_join_keys).each do |key, value|
            row[key] = value
          end
        end

      end

      new_nodes[stmt.node_name] = [] if new_nodes[stmt.node_name].nil?
      new_nodes[stmt.node_name].insert(-1, row)

    end

    new_nodes
  end

end # class LogStash::Filters::Jdbc
