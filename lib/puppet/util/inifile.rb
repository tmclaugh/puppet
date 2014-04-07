# Module Puppet::IniConfig
# A generic way to parse .ini style files and manipulate them in memory
# One 'file' can be made up of several physical files. Changes to sections
# on the file are tracked so that only the physical files in which
# something has changed are written back to disk
# Great care is taken to preserve comments and blank lines from the original
# files
#
# The parsing tries to stay close to python's ConfigParser

require 'puppet/util/filetype'
require 'puppet/error'

module Puppet::Util::IniConfig
  # A section in a .ini file
  class Section
    attr_reader :name, :file, :entries
    attr_writer :destroy

    def initialize(name, file)
      @name = name
      @file = file
      @dirty = false
      @entries = []
      @destroy = false
    end

    # Does this section need to be updated in/removed from the associated file?
    #
    # @note This section is dirty if a key has been modified _or_ if the
    #   section has been modified so the associated file can be rewritten
    #   without this section.
    def dirty?
      @dirty or @destroy
    end

    def mark_dirty
      @dirty = true
    end

    # Should only be used internally
    def mark_clean
      @dirty = false
    end

    # Should the file be destroyed?
    def destroy?
      @destroy
    end

    # Add a line of text (e.g., a comment) Such lines
    # will be written back out in exactly the same
    # place they were read in
    def add_line(line)
      @entries << line
    end

    # Set the entry 'key=value'. If no entry with the
    # given key exists, one is appended to teh end of the section
    def []=(key, value)
      entry = find_entry(key)
      @dirty = true
      if entry.nil?
        @entries << [key, value]
      else
        entry[1] = value
      end
    end

    # Return the value associated with KEY. If no such entry
    # exists, return nil
    def [](key)
      entry = find_entry(key)
      return(entry.nil? ? nil : entry[1])
    end

    # Format the section as text in the way it should be
    # written to file
    def format
      if @destroy
        text = ""
      else
        text = "[#{name}]\n"
        @entries.each do |entry|
          if entry.is_a?(Array)
            key, value = entry
            text << "#{key}=#{value}\n" unless value.nil?
          else
            text << entry
          end
        end
      end
      text
    end

    private
    def find_entry(key)
      @entries.each do |entry|
        return entry if entry.is_a?(Array) && entry[0] == key
      end
      nil
    end

  end

  # A logical .ini-file that can be spread across several physical
  # files. For each physical file, call #read with the filename
  class File
    def initialize
      @files = {}
    end

    # Add the contents of the file with name FILE to the
    # already existing sections
    def read(file)
      text = Puppet::Util::FileType.filetype(:flat).new(file).read
      raise "Could not find #{file}" if text.nil?

      section = nil   # The name of the current section
      optname = nil   # The name of the last option in section
      line = 0
      @files[file] = []
      text.each_line do |l|
        line += 1
        if l.strip.empty? || "#;".include?(l[0,1]) ||
            (l.split(nil, 2)[0].downcase == "rem" && l[0,1].downcase == "r")
          # Whitespace or comment
          if section.nil?
            @files[file] << l
          else
            section.add_line(l)
          end
        elsif " \t\r\n\f".include?(l[0,1]) && section && optname
          # continuation line
          section[optname] += "\n#{l.chomp}"
        elsif l =~ /^\[([^\]]+)\]/
          # section heading
          section.mark_clean unless section.nil?
          section = add_section($1, file)
          optname = nil
        elsif l =~ /^\s*([^\s=]+)\s*\=(.*)$/
          # We allow space around the keys, but not the values
          # For the values, we don't know if space is significant
          if section.nil?
            raise "#{file}:#{line}:Key/value pair outside of a section for key #{$1}"
          else
            section[$1] = $2
            optname = $1
          end
        else
          raise "#{file}:#{line}: Can't parse '#{l.chomp}'"
        end
      end
      section.mark_clean unless section.nil?
    end

    # Store all modifications made to sections in this file back
    # to the physical files. If no modifications were made to
    # a physical file, nothing is written
    def store
      @files.each do |file, lines|
        text = ""
        dirty = false
        destroy = false
        lines.each do |l|
          if l.is_a?(Section)
            destroy ||= l.destroy?
            dirty ||= l.dirty?
            text << l.format
            l.mark_clean
          else
            text << l
          end
        end
        # We delete the file and then remove it from the list of files.
        if destroy
          ::File.unlink(file)
          @files.delete(file)
        else
          if dirty
            Puppet::Util::FileType.filetype(:flat).new(file).write(text)
            return file
          end
        end
      end
    end

    # Execute BLOCK, passing each section in this file
    # as an argument
    def each_section(&block)
      @files.each do |file, list|
        list.each do |entry|
          yield(entry) if entry.is_a?(Section)
        end
      end
    end

    # Execute BLOCK, passing each file constituting this inifile
    # as an argument
    def each_file(&block)
      @files.keys.each do |file|
        yield(file)
      end
    end

    # Return the Section with the given name or nil
    def [](name)
      name = name.to_s
      each_section do |section|
        return section if section.name == name
      end
      nil
    end

    # Return true if the file contains a section with name NAME
    def include?(name)
      ! self[name].nil?
    end

    # Add a section to be stored in FILE when store is called
    def add_section(name, file)
      raise "A section with name #{name} already exists" if include?(name)
      result = Section.new(name, file)
      @files[file] ||= []
      @files[file] << result
      result
    end
  end

  class PhysicalFile

    # @!attribute [r] filetype
    #   @api private
    #   @return [Puppet::Util::FileType::FileTypeFlat]
    attr_reader :filetype

    # @!attribute [r] contents
    #   @api private
    #   @return [Array<String, Puppet::Util::IniConfig::Section>]
    attr_reader :contents

    # @!attribute [rw] destroy_empty
    #   Whether empty files should be removed if no sections are defined.
    #   Defaults to false
    attr_accessor :destroy_empty

    def initialize(file, options = {})
      @file = file
      @contents = []
      @filetype = Puppet::Util::FileType.filetype(:flat).new(file)

      @destroy_empty = options.fetch(:destroy_empty, false)
    end

    # Read and parse the on-disk file associated with this object
    def read
      text = @filetype.read
      if text.nil?
        raise IniParseError, "Cannot read nonexistent file #{@file.inspect}"
      end
      parse(text)
    end

    INI_COMMENT = Regexp.union(
      /^\s*$/,
      /^[#;]/,
      /^\s*rem\s/i
    )
    INI_CONTINUATION = /^[ \t\r\n\f]/
    INI_SECTION_NAME = /^\[([^\]]+)\]/
    INI_PROPERTY     = /^\s*([^\s=]+)\s*\=(.*)$/

    # @api private
    def parse(text)
      section = nil   # The name of the current section
      optname = nil   # The name of the last option in section
      line_num = 0

      text.each_line do |l|
        line_num += 1
        if l.match(INI_COMMENT)
          # Whitespace or comment
          if section.nil?
            @contents << l
          else
            section.add_line(l)
          end
        elsif l.match(INI_CONTINUATION) && section && optname
          # continuation line
          section[optname] += "\n#{l.chomp}"
        elsif (match = l.match(INI_SECTION_NAME))
          # section heading
          section.mark_clean if section

          section_name = match[1]

          if get_section(section_name)
            raise IniParseError.new(
              "Section #{section_name.inspect} is already defined, cannot redefine", @file, line_num
            )
          end

          section = add_section(section_name)
          optname = nil
        elsif (match = l.match(INI_PROPERTY))
          # We allow space around the keys, but not the values
          # For the values, we don't know if space is significant
          key = match[1]
          val = match[2]

          if section.nil?
            raise IniParseError.new("Property with key #{key.inspect} outside of a section")
          end

          section[key] = val
          optname = key
        else
          raise IniParseError.new("Can't parse line '#{l.chomp}'", @file, line_num)
        end
      end
      section.mark_clean unless section.nil?
    end

    # @return [Array<Puppet::Util::IniConfig::Section>] All sections defined in
    #   this file.
    def sections
      @contents.select { |entry| entry.is_a? Section }
    end

    # @return [Puppet::Util::IniConfig::Section, nil] The section with the
    #   given name if it exists, else nil.
    def get_section(name)
      @contents.find { |entry| entry.is_a? Section and entry.name == name }
    end

    def format
      text = ""

      @contents.each do |content|
        if content.is_a? Section
          text << content.format
        else
          text << content
        end
      end

      text
    end

    def store
      if @destroy_empty and (sections.empty? or sections.all?(&:destroy?))
        ::File.unlink(@file)
      elsif sections.any?(&:dirty?)
        text = self.format
        @filetype.write(text)
      end
      sections.each(&:mark_clean)
    end

    # Create a new section and store it in the file contents
    #
    # @api private
    # @param name [String] The name of the section to create
    # @return [Puppet::Util::IniConfig::Section]
    def add_section(name)
      section = Section.new(name, @file)
      @contents << section

      section
    end
  end

  class FileCollection

    attr_reader :files

    def initialize
      @files = {}
    end

    def read(file)
      physical_file = PhysicalFile.new(file)
      physical_file.read
      @files[file] = physical_file
    end

    def store
      @files.values.each do |file|
        file.store
      end
    end

    def each_section(&block)
      @files.values.each do |file|
        file.sections.each do |section|
          yield section
        end
      end
    end

    def each_file(&block)
      @files.keys.each do |path|
        yield path
      end
    end

    def get_section(name)
      sect = nil
      @files.values.each do |file|
        if (current = file.get_section(name))
          sect = current
        end
      end
      sect
    end
    alias [] get_section

    def include?(name)
      !! get_section(name)
    end

    def add_section(name, file)
      @files[file] ||= PhysicalFile.new(file)
      @files[file].add_section(name)
    end
  end

  class IniParseError < Puppet::Error
    include Puppet::ExternalFileError
  end
end
