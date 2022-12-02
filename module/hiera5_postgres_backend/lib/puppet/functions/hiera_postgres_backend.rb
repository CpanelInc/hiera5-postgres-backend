# Copyright 2018 cPanel, LLC
# Derived in part from works copyright 2017 Craig Dunn and 2013 Adrian Lopez, licensed under MIT and Apache licenses.:
#
# Copyright 2017 Craig Dunn <craig@craigdunn.org>
# https://github.com/crayfishx/hiera-mysql/blob/master/LICENSE
#
# Copyright 2013 Adrian Lopez
# https://github.com/adrianlzt/hiera-postgres-backend/blob/master/LICENSE
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
# Class hiera5_postgres_backend
# Description: Postgres back end to Hiera 5.
# Author: Christopher E. Stith <chris.stith@cpanel.net>
#
#
Puppet::Functions.create_function(:hiera_postgres_backend) do
  begin
    require 'pg'
  rescue LoadError
    raise Puppet::DataBinding::LookupError, 'Error loading pg gem library.'
  end

  dispatch :postgres_lookup_key do
    param 'Variant[String, Numeric]', :key
    param 'Hash', :options
    param 'Puppet::LookupContext', :context
  end

  Puppet::Util::Warnings.clear_warnings

  def postgres_lookup_key(key, options, context)
    path = options['path']
    query_file = context.cached_file_data(path) do |content|
      begin
        context.interpolate(YAML.safe_load(content))
      rescue
        raise Puppet::DataBinding::LookupError, "Unable to parse (#{path})"
      end
    end

    key_parts = key.split(/::/)

    psql_query =
      if query_file.include?(key)
        context.explain { "Found #{key} in #{path}" }
        query_file[key]
      elsif query_file.include?(key_parts.last)
        context.explain { "Found last part of key <#{key}>, <#{key_parts.last}>, in #{path}" }
        query_file[key_parts.last]
      elsif query_file.include?('default_query')
        context.explain { "Found default_query in #{path}" }
        query_file['default_query']
      else
        context.explain { "Found no suitable query in #{path} for key #{key}" }
        context.not_found
      end

    if context.cache_has_key(psql_query)
      context.explain { "Returning cached value for #{psql_query}" }
      return context.cached_value(psql_query)
    end

    context.explain { "Postgres Lookup with query: #{psql_query}" }
    results = query(psql_query, context, options)

    if !defined? results
      context.not_found
      return nil
    elsif results.nil?
      context.not_found
      return nil
    elsif results.empty?
      context.not_found
      return nil
    else
      return results if options['return'] == 'array'
      return results[0] if options['return'] == 'first'
      return (results.length > 1) ? results : results[0]
    end
  end

  def query(sql, context, options)
    data = []

    Puppet::Util::Warnings.warnonce("sql: #{sql}")
    #
    if context.cache_has_key('_client')
      client = context.cached_value('_client')
    else
      password =
        if options['pass_file']
          pf = options['pass_file']
          if File.file?(pf)
            pw = YAML.safe_load(File.read(pf))
            pw['hiera5_postgres_backend_password']
          else
            context.explain { "Cannot read DB password from #{pf}" }
            raise Puppet::DataBinding::LookupError, 'Error reading password from password file.'
          end
        elsif options['pass']
          options['pass']
        end
      client = PGconn.open(
        host:     options['host'],
        user:     options['user'],
        password: password,
        dbname:   options['database'],
      )

      # Do not cache the client object as there's no way to force it out of scope and therefor no way to close connections
      # See: https://tickets.puppetlabs.com/browse/PUP-8088
      # The ensure clause below enforces connection close on each lookup
      # context.cache('_client', client)

    end

    begin
      rows = client.exec(sql)
      if rows.fields.count == 1 && rows.count == 1
        data = context.interpolate(rows[0][rows.fields[0]])
      elsif rows.fields.count == 1 && rows.count > 1
        ary = []
        rows.each { |row| ary.push(context.interpolate(row[rows.fields[0]])) }
        data = ary
      else
        data = context.interpolate(rows.to_a)
      end
      context.explain { 'returned rows ' + rows.count.to_s + ' columns ' + rows.fields.count.to_s }
    rescue => e
      context.explain { '<<error running the query "' + sql + ' :: ' + e.message + '>>' }
      Puppet::Util::Warnings.warnonce('<<error running the query "' + sql + ' :: ' + e.message + '>>')
      data = nil
    ensure
      client.close if client
    end
    data
  end
end
