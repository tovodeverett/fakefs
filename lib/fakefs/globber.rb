module FakeFS
  # Handles globbing for FakeFS.
  module Globber
    module PatternParser
      extend self

      def build_matcher(pattern, descendent=nil)
        matcher = nil

        Globber.path_components(pattern).reverse.each do |part|
          matcher = new_matcher(part, matcher)
        end

        return matcher
      end

      private

      def new_matcher(pattern, descendent=nil)
        case pattern
        when '**'
          if descendent.nil?
            Matcher::Regexp.new(/\A.*\Z/, nil)
          else
            Matcher::DirRecursor.new(descendent)
          end
        when /\A\{.*\}\Z/
          matchers = Globber.expand(pattern).map do |subpattern|
            build_matcher(subpattern, descendent)
          end
          Matcher::Alternator.new(matchers)
        else
          alternatives = split_multidir_alternation_pattern(pattern)
          if alternatives.length > 1
            matchers = alternatives.map do |alternative|
              build_matcher(alternative, descendent)
            end
            Matcher::Alternator.new(matchers)
          else
            Matcher::Regexp.new(Globber.regexp(pattern), descendent)
          end
        end
      end

      def split_multidir_alternation_pattern(pattern)
        if pattern =~ /\{/
          pre_alternation = ''
          multidir_alternation = nil
          post_alternation = nil

          while pattern.length > 0
            unless pattern =~ /\A(?:[^{}]+|(?<re>\{(?:(?>[^{}]+)|\g<re>)*\}))/
              raise StandardError.new("Failed to parse '#{pattern}'")
            end
            chunk = Regexp.last_match[0]
            pattern = Regexp.last_match.post_match
            if chunk =~ /\A\{(.*\/.*)\}\Z/
              multidir_alternation = Regexp.last_match[1]
              post_alternation = pattern
              pattern = ''
            else
              pre_alternation += chunk
            end
          end

          if multidir_alternation.nil?
            return [pattern]
          else
            alternates = []
            while multidir_alternation.length > 0
              unless multidir_alternation =~ /\A[^{},]*(?<re>\{(?:(?>[^{}]+)|\g<re>)*\})?[^{},]*(?:,|\Z)/
                raise StandardError.new("Failed to parse '#{multidir_alternation}'")
              end
              chunk = Regexp.last_match[0]
              multidir_alternation = Regexp.last_match.post_match
              alternates.push(chunk.sub(/,\Z/, ''))
            end
            return alternates.map { |a| pre_alternation + a + post_alternation }
          end
        else
          return [pattern]
        end
      end
    end

    class Matcher
      attr_accessor :descendent

      def matches(entry)
        if entry.is_a?(FakeDir) || ( entry.is_a?(FakeSymlink) && entry.entry.is_a?(FakeDir) )
          _matches(entry)
        else
          []
        end
      end

      def _matches(dir)
        raise NotImplementedError.new("#{self.class.name}#_matches is an abstract method.")
      end

      def find(dir)
        if leaf?
          matches(dir)
        else
          matches(dir).map { |m| descendent.find(m) }.flatten
        end
      end

      def leaf?
        descendent.nil?
      end

      class DirRecursor < Matcher
        def initialize(descendent)
          @descendent = descendent
        end

        def _matches(dir)
          subdirs = dir.entries.select { |f| f.is_a?(FakeDir) }
          ([dir] + subdirs.map { |d| matches(d) }).flatten
        end
      end

      class Alternator < Matcher
        attr_reader :matchers

        def initialize(matchers)
          @matchers = matchers
        end

        def _matches(dir)
          matchers.map { |m| m.find(dir) }.flatten
        end
      end

      class Regexp < Matcher
        attr_reader :regexp

        def initialize(regexp, descendent)
          @regexp = regexp
          @descendent = descendent
        end

        def _matches(dir)
          dir.matches(regexp)
        end
      end
    end

    extend self

    def expand(pattern)
      pattern = pattern.to_s

      return [pattern] if pattern[0] != '{' || pattern[-1] != '}'

      part = ''
      result = []

      each_char_with_levels pattern, '{', '}' do |chr, level|
        case level
        when 0
          case chr
          when '{'
            # noop
          else
            part << chr
          end
        when 1
          case chr
          when ','
            result << part
            part = ''
          when '}'
            # noop
          else
            part << chr
          end
        else
          part << chr
        end
      end

      result << part

      result
    end

    def path_components(pattern)
      pattern = pattern.to_s

      part = ''
      result = []

      each_char_with_levels pattern, '{', '}' do |chr, level|
        if level == 0 && chr == File::SEPARATOR
          result << part
          part = ''
        else
          part << chr
        end
      end

      result << part

      drop_root(result).reject(&:empty?)
    end

    def regexp(pattern)
      pattern = pattern.to_s

      regex_body = pattern.gsub('.', '\.')
                   .gsub('+') { '\+' }
                   .gsub('?', '.')
                   .gsub('*', '.*')
                   .gsub('(', '\(')
                   .gsub(')', '\)')
                   .gsub('$', '\$')

      # This matches nested braces and attempts to do something correct most of the time
      # There are known issues (i.e. {,*,*/*}) that cannot be resolved with out a total
      # refactoring
      loop do
        break unless regex_body.gsub!(/(?<re>\{(?:(?>[^{}]+)|\g<re>)*\})/) do
          "(#{Regexp.last_match[1][1..-2].gsub(',', '|')})"
        end
      end

      regex_body = regex_body.gsub(/\A\./, '(?!\.).')

      /\A#{regex_body}\Z/
    end

    private

    def each_char_with_levels(string, level_start, level_end)
      level = 0

      string.each_char do |chr|
        yield chr, level

        case chr
        when level_start
          level += 1
        when level_end
          level -= 1
        end
      end
    end

    def drop_root(path_parts)
      # we need to remove parts from root dir at least for windows and jruby
      return path_parts if path_parts.nil? || path_parts.empty?
      root = RealFile.expand_path('/').split(File::SEPARATOR).first
      path_parts.shift if path_parts.first == root
      path_parts
    end
  end
end
