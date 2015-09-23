module Csvlint

  class Validator

    include Csvlint::ErrorCollector

    attr_reader :encoding, :content_type, :extension, :headers, :link_headers, :line_breaks, :dialect, :csv_header, :schema, :data

    ERROR_MATCHERS = {
      "Missing or stray quote" => :stray_quote,
      "Illegal quoting" => :whitespace,
      "Unclosed quoted field" => :unclosed_quote,
      "Unquoted fields do not allow \\r or \\n" => :line_breaks,
    }

    def initialize(source, dialect = nil, schema = nil, options = {})
      reset
      @source = source
      @formats = []
      @schema = schema

      @supplied_dialect = dialect != nil

      @limit_lines = options[:limit_lines]
      @extension = parse_extension(source) unless @source.nil?
      @errors += @schema.errors unless @schema.nil?
      @warnings += @schema.warnings unless @schema.nil?
      validate(dialect)

    end

    def validate(dialect = nil)
      single_col = false
      io = nil
      begin
        if @extension =~ /.xls(x)?/
          build_warnings(:excel, :context)
          return
        end
        io = @source.respond_to?(:gets) ? @source : open(@source, :allow_redirections=>:all)
        validate_metadata(io)
        locate_schema unless @schema.instance_of?(Csvlint::Schema)
        set_dialect(dialect)
        parse_csv(io)
        sum = @col_counts.inject(:+)
        unless sum.nil?
          build_warnings(:title_row, :structure) if @col_counts.first < (sum / @col_counts.size.to_f)
        end
        build_warnings(:check_options, :structure) if @expected_columns == 1
        check_consistency
        check_foreign_keys
      rescue OpenURI::HTTPError, Errno::ENOENT
        build_errors(:not_found, nil, nil, nil, @source)
      ensure
        io.close if io && io.respond_to?(:close)
      end
    end

    def validate_metadata(io)
      @csv_header = true
      @encoding = io.charset rescue nil
      @content_type = io.content_type rescue nil
      @headers = io.meta rescue nil
      @link_headers = @headers["link"].split(",") rescue nil
      assumed_header = undeclared_header = !@supplied_dialect
      if @headers
        if @headers["content-type"] =~ /text\/csv/
          @csv_header = true
          undeclared_header = false
          assumed_header = true
        end
        if @headers["content-type"] =~ /header=(present|absent)/
          @csv_header = true if $1 == "present"
          @csv_header = false if $1 == "absent"
          undeclared_header = false
          assumed_header = false
        end
        if @headers["content-type"] !~ /charset=/
          build_warnings(:no_encoding, :context)
        else
          build_warnings(:encoding, :context) if @encoding != "utf-8"
        end
        build_warnings(:no_content_type, :context) if @content_type == nil
        build_errors(:wrong_content_type, :context) unless (@content_type && @content_type =~ /text\/csv/)

        if undeclared_header
          build_errors(:undeclared_header, :structure)
          assumed_header = false
        end

      end
      build_info_messages(:assumed_header, :structure) if assumed_header
    end

    def set_dialect(dialect)
      begin
        schema_dialect = @schema.tables[@source_url].dialect || {}
      rescue
        schema_dialect = {}
      end
      @dialect = {
        "header" => true,
        "delimiter" => ",",
        "skipInitialSpace" => true,
        "lineTerminator" => :auto,
        "quoteChar" => '"',
        "trim" => :true
      }.merge(schema_dialect).merge(dialect || {})

      @csv_header = @csv_header && @dialect["header"]
      @csv_options = dialect_to_csv_options(@dialect)
    end

    # analyses the provided csv and builds errors, warnings and info messages
    def parse_csv(io)
      @expected_columns = 0
      current_line = 0
      reported_invalid_encoding = false
      all_errors = []
      @col_counts = []

      @csv_options[:encoding] = @encoding

      begin
        wrapper = WrappedIO.new( io )
        csv = CSV.new( wrapper, @csv_options )
        @data = []
        @line_breaks = csv.row_sep
        if @line_breaks != "\r\n"
          build_info_messages(:nonrfc_line_breaks, :structure)
        end
        row = nil
        loop do
         current_line += 1
         if @limit_lines && current_line > @limit_lines
           break
         end
         begin
           wrapper.reset_line
           row = csv.shift
           @data << row
           if row
             if current_line == 1 && header?
               row = row.reject{|col| col.nil? || col.empty?}
               validate_header(row)
               @col_counts << row.size
             else
               build_formats(row)
               @col_counts << row.reject{|col| col.nil? || col.empty?}.size
               @expected_columns = row.size unless @expected_columns != 0

               build_errors(:blank_rows, :structure, current_line, nil, wrapper.line) if row.reject{ |c| c.nil? || c.empty? }.size == 0
               # Builds errors and warnings related to the provided schema file
               if @schema
                 @schema.validate_row(row, current_line, all_errors, @source)
                 @errors += @schema.errors
                 all_errors += @schema.errors
                 @warnings += @schema.warnings
               else
                 build_errors(:ragged_rows, :structure, current_line, nil, wrapper.line) if !row.empty? && row.size != @expected_columns
               end

             end
           else
             break
           end
         rescue CSV::MalformedCSVError => e
           type = fetch_error(e)
           if type == :stray_quote && !wrapper.line.match(csv.row_sep)
             build_errors(:line_breaks, :structure)
           else
             build_errors(type, :structure, current_line, nil, wrapper.line)
           end
         end
      end
      rescue ArgumentError => ae
        build_errors(:invalid_encoding, :structure, current_line, nil, wrapper.line) unless reported_invalid_encoding
        reported_invalid_encoding = true
      end
    end

    def validate_header(header)
      names = Set.new
      header.map{|h| h.strip! } if @dialect["trim"] == :true
      header.each_with_index do |name,i|
        build_warnings(:empty_column_name, :schema, nil, i+1) if name == ""
        if names.include?(name)
          build_warnings(:duplicate_column_name, :schema, nil, i+1)
        else
          names << name
        end
      end
      if @schema
        @schema.validate_header(header, @source)
        @errors += @schema.errors
        @warnings += @schema.warnings
      end
      return valid?
    end

    def header?
      @csv_header
    end

    def fetch_error(error)
      e = error.message.match(/^(.+?)(?: [io]n)? \(?line \d+\)?\.?$/i)
      message = e[1] rescue nil
      ERROR_MATCHERS.fetch(message, :unknown_error)
    end

    def dialect_to_csv_options(dialect)
        skipinitialspace = dialect["skipInitialSpace"] || true
        delimiter = dialect["delimiter"]
        delimiter = delimiter + " " if !skipinitialspace
        return {
            :col_sep => delimiter,
            :row_sep => dialect["lineTerminator"],
            :quote_char => dialect["quoteChar"],
            :skip_blanks => false
        }
    end

    def build_formats(row)
      row.each_with_index do |col, i|
        next if col.nil? || col.empty?
        @formats[i] ||= Hash.new(0)

        format = if col.strip[FORMATS[:numeric]]
          :numeric
        elsif uri?(col)
          :uri
        elsif col[FORMATS[:date_db]] && date_format?(Date, col, '%Y-%m-%d')
          :date_db
        elsif col[FORMATS[:date_short]] && date_format?(Date, col, '%e %b')
          :date_short
        elsif col[FORMATS[:date_rfc822]] && date_format?(Date, col, '%e %b %Y')
          :date_rfc822
        elsif col[FORMATS[:date_long]] && date_format?(Date, col, '%B %e, %Y')
          :date_long
        elsif col[FORMATS[:dateTime_time]] && date_format?(Time, col, '%H:%M')
          :dateTime_time
        elsif col[FORMATS[:dateTime_hms]] && date_format?(Time, col, '%H:%M:%S')
          :dateTime_hms
        elsif col[FORMATS[:dateTime_db]] && date_format?(Time, col, '%Y-%m-%d %H:%M:%S')
          :dateTime_db
        elsif col[FORMATS[:dateTime_iso8601]] && date_format?(Time, col, '%Y-%m-%dT%H:%M:%SZ')
          :dateTime_iso8601
        elsif col[FORMATS[:dateTime_short]] && date_format?(Time, col, '%d %b %H:%M')
          :dateTime_short
        elsif col[FORMATS[:dateTime_long]] && date_format?(Time, col, '%B %d, %Y %H:%M')
          :dateTime_long
        else
          :string
        end

        @formats[i][format] += 1
      end
    end

    def check_consistency
      @formats.each_with_index do |format,i|
        if format
          total = format.values.reduce(:+).to_f
          if format.none?{|_,count| count / total >= 0.9}
            build_warnings(:inconsistent_values, :schema, nil, i + 1)
          end
        end
      end
    end

    def check_foreign_keys
      if @schema.instance_of? Csvlint::Csvw::TableGroup
        @schema.validate_foreign_keys
        @errors += @schema.errors
        @warnings += @schema.warnings
      end
    end

    def locate_schema
      @source_url = nil
      warn_if_unsuccessful = false
      case @source
      when StringIO
        return
      when File
        @source_url = "file:#{File.expand_path(@source)}"
      else
        @source_url = @source
      end
      unless @schema.nil?
        if @schema.tables[@source_url]
          return
        else
          @schema = nil
        end
      end
      link_schema = nil
      @link_headers.each do |link_header|
        match = LINK_HEADER_REGEXP.match(link_header)
        uri = match["uri"].gsub(/(^\<|\>$)/, "")
        rel = match["rel-relationship"].gsub(/(^\"|\"$)/, "")
        param = match["param"]
        param_value = match["param-value"].gsub(/(^\"|\"$)/, "")
        if rel == "describedby" && param == "type" && ["application/csvm+json", "application/ld+json", "application/json"].include?(param_value)
          begin
            url = URI.join(@source_url, uri)
            schema = Schema.load_from_json(url)
            if schema.instance_of? Csvlint::Csvw::TableGroup
              if schema.tables[@source_url]
                link_schema = schema
              else
                warn_if_unsuccessful = true
                build_warnings(:schema_mismatch, :context, nil, nil, @source_url, schema)
              end
            end
          rescue OpenURI::HTTPError
          end
        end
      end if @link_headers
      @schema = link_schema if link_schema

      paths = []
      if @source_url =~ /^http(s)?/
        begin
          well_known_uri = URI.join(@source_url, "/.well-known/csvm")
          well_known = open(well_known_uri).read
          # TODO
        rescue OpenURI::HTTPError
        end
      end
      paths = ["{+url}-metadata.json", "csv-metadata.json"] if paths.empty?
      paths.each do |template|
        begin
          template = URITemplate.new(template)
          path = template.expand('url' => @source_url)
          url = URI.join(@source_url, path)
          url = File.new(url.to_s.sub(/^file:/, "")) if url.to_s =~ /^file:/
          schema = Schema.load_from_json(url)
          if schema.instance_of? Csvlint::Csvw::TableGroup
            if schema.tables[@source_url]
              @schema = schema
            else
              warn_if_unsuccessful = true
              build_warnings(:schema_mismatch, :context, nil, nil, @source_url, schema)
            end
          end
        rescue Errno::ENOENT
        rescue OpenURI::HTTPError
        rescue => e
          STDERR.puts e.class
          STDERR.puts e.message
          STDERR.puts e.backtrace
          raise e
        end
      end
      build_warnings(:schema_mismatch, :context, nil, nil, @source_url, schema) if warn_if_unsuccessful
      @schema = nil
    end

    private

    def parse_extension(source)
      case source
      when File
        return File.extname( source.path )
      when IO
        return ""
      when StringIO
        return ""
        when Tempfile
          # this is triggered when the revalidate dialect use case happens
        return ""
      else
        begin
          parsed = URI.parse(source)
          File.extname(parsed.path)
        rescue URI::InvalidURIError
          return ""
        end
      end
    end

    def uri?(value)
      if value.strip[FORMATS[:uri]]
        uri = URI.parse(value)
        uri.kind_of?(URI::HTTP) || uri.kind_of?(URI::HTTPS)
      end
    rescue URI::InvalidURIError
      false
    end

    def date_format?(klass, value, format)
      klass.strptime(value, format).strftime(format) == value
    rescue ArgumentError # invalid date
      false
    end

    FORMATS = {
      :string => nil,
      :numeric => /\A[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?\z/,
      :uri => /\Ahttps?:/,
      :date_db => /\A\d{4,}-\d\d-\d\d\z/,                                               # "12345-01-01"
      :date_long => /\A(?:#{Date::MONTHNAMES.join('|')}) [ \d]\d, \d{4,}\z/,            # "January  1, 12345"
      :date_rfc822 => /\A[ \d]\d (?:#{Date::ABBR_MONTHNAMES.join('|')}) \d{4,}\z/,      # " 1 Jan 12345"
      :date_short => /\A[ \d]\d (?:#{Date::ABBR_MONTHNAMES.join('|')})\z/,              # "1 Jan"
      :dateTime_db => /\A\d{4,}-\d\d-\d\d \d\d:\d\d:\d\d\z/,                            # "12345-01-01 00:00:00"
      :dateTime_hms => /\A\d\d:\d\d:\d\d\z/,                                            # "00:00:00"
      :dateTime_iso8601 => /\A\d{4,}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/,                      # "12345-01-01T00:00:00Z"
      :dateTime_long => /\A(?:#{Date::MONTHNAMES.join('|')}) \d\d, \d{4,} \d\d:\d\d\z/, # "January 01, 12345 00:00"
      :dateTime_short => /\A\d\d (?:#{Date::ABBR_MONTHNAMES.join('|')}) \d\d:\d\d\z/,   # "01 Jan 00:00"
      :dateTime_time => /\A\d\d:\d\d\z/,                                                # "00:00"
    }.freeze

    URI_REGEXP = /(?<uri>.*?)/
    TOKEN_REGEXP = /([^\(\)\<\>@,;:\\"\/\[\]\?=\{\} \t]+)/
    QUOTED_STRING_REGEXP = /("[^"]*")/
    SGML_NAME_REGEXP = /([A-Za-z][-A-Za-z0-9\.]*)/
    RELATIONSHIP_REGEXP = Regexp.new("(?<relationship>#{SGML_NAME_REGEXP}|(\"#{SGML_NAME_REGEXP}(\\s+#{SGML_NAME_REGEXP})*\"))")
    REL_REGEXP = Regexp.new("(?<rel>\\s*rel\\s*=\\s*(?<rel-relationship>#{RELATIONSHIP_REGEXP}))")
    REV_REGEXP = Regexp.new("(?<rev>\\s*rev\\s*=\\s*#{RELATIONSHIP_REGEXP})")
    TITLE_REGEXP = Regexp.new("(?<title>\\s*title\\s*=\\s*#{QUOTED_STRING_REGEXP})")
    ANCHOR_REGEXP = Regexp.new("(?<anchor>\\s*anchor\\s*=\\s*\\<#{URI_REGEXP}\\>)")
    LINK_EXTENSION_REGEXP = Regexp.new("(?<link-extension>(?<param>#{TOKEN_REGEXP})(\\s*=\\s*(?<param-value>#{TOKEN_REGEXP}|#{QUOTED_STRING_REGEXP}))?)")
    LINK_PARAM_REGEXP = Regexp.new("(#{REL_REGEXP}|#{REV_REGEXP}|#{TITLE_REGEXP}|#{ANCHOR_REGEXP}|#{LINK_EXTENSION_REGEXP})")
    LINK_HEADER_REGEXP = Regexp.new("\<#{URI_REGEXP}\>(\\s*;\\s*#{LINK_PARAM_REGEXP})*")

  end
end
