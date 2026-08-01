# frozen_string_literal: true
require 'strscan'

module YARD
  module Tags
    class TypesExplainer
      # Regular expression to match symbol and string literals
      LITERALMATCH = /:\w+|'[^']*'|"[^"]*"/

      # (see Tag#explain_types)
      # @param types [Array<String>] a list of types to parse and summarize
      def self.explain(*types)
        explain!(*types)
      rescue SyntaxError
        nil
      end

      # (see explain)
      # @raise [SyntaxError] if the types are not parsable
      def self.explain!(*types)
        Parser.parse(types.join(", ")).join("; ")
      end

      class << self
        private :new
      end

      # @private
      class Type
        attr_accessor :name

        def initialize(name)
          @name = name
        end

        def to_s(singular = true)
          if name[0, 1] =~ /[A-Z]/
            singular ? "a#{name[0, 1] =~ /[aeiou]/i ? 'n' : ''} " + name : "#{name}#{name[-1, 1] =~ /[A-Z]/ ? "'" : ''}s"
          else
            name
          end
        end

        protected

        def list_join(list, with: "or")
          index = 0
          list.inject(String.new) do |acc, el|
            acc << el.to_s
            acc << ", " if index < list.size - 2
            acc << " #{with} " if index == list.size - 2
            index += 1
            acc
          end
        end
      end

      # @private
      class LiteralType < Type
        def to_s(_singular = true)
          "a literal value #{name}"
        end
      end

      # @private
      class DuckType < Type
        def to_s(singular = true)
          (singular ? "an object that responds to " : "objects that respond to ") + list_join(name.split(/ *& */), with: "and")
        end
      end

      # @private
      class IntersectionType < Type
        attr_accessor :types

        def initialize(types)
          @types = types
        end

        def to_s(singular = true)
          # A leading "both"/"all of" disambiguates a single value
          # satisfying every listed type from what "a Foo and a Bar" alone
          # could otherwise read as - two separate things.
          prefix = types.size == 2 ? "both " : "all of "
          prefix + list_join(types.map {|t| t.to_s(singular) }, with: "and")
        end
      end

      # @private
      class GroupType < Type
        attr_accessor :types

        def initialize(types)
          @types = types
        end

        def to_s(singular = true)
          "(" + list_join(types.map {|t| disambiguate(t, singular) }) + ")"
        end

        private

        # {IntersectionType} and a multi-method {DuckType} (`#foo & #bar`)
        # both render as a bare "X and Y", with no punctuation of their own
        # to mark where they end. Sitting next to a sibling in this group's
        # own "or"-joined list, that reads ambiguously (e.g. "a Foo and a
        # Bar or a Baz" doesn't show whether the "and" or the "or" binds
        # tighter) even though the parse itself is unambiguous. Wrap those
        # two cases in their own parens so the group's members are visually
        # self-delimiting; every other {Type} already is (a bare name, or
        # something with its own bracketing like {GroupType} itself).
        def disambiguate(type, singular)
          rendered = type.to_s(singular)
          needs_parens = type.is_a?(IntersectionType) ||
                         (type.is_a?(DuckType) && type.name.include?('&'))
          needs_parens ? "(#{rendered})" : rendered
        end
      end

      # @private
      class CollectionType < Type
        attr_accessor :types

        def initialize(name, types)
          @name = name
          @types = types
        end

        def to_s(_singular = true)
          "a#{name[0, 1] =~ /[aeiou]/i ? 'n' : ''} #{name} of (" + list_join(types.map {|t| t.to_s(false) }) + ")"
        end
      end

      # @private
      #
      # Unlike {CollectionType}, this doesn't assert that its type
      # parameters are alternatives ("of (A's or B's)") - `<...>` is
      # conventionally used both ways (a homogeneous collection's element
      # type(s), or a class's distinct positional type-parameter roles,
      # e.g. `Result<Success, Failure>`), and there's no way for YARD to
      # know which one a given class means. This is the honest fallback
      # for any name not specifically known to mean the former.
      class ParametrizedType < Type
        attr_accessor :types

        def initialize(name, types)
          @name = name
          @types = types
        end

        def to_s(_singular = true)
          "a#{name[0, 1] =~ /[aeiou]/i ? 'n' : ''} #{name} with type parameters (" +
            types.map {|t| t.to_s(true) }.join(", ") + ")"
        end
      end

      # @private
      class FixedCollectionType < CollectionType
        def to_s(_singular = true)
          "a#{name[0, 1] =~ /[aeiou]/i ? 'n' : ''} #{name} containing (" + types.map(&:to_s).join(" followed by ") + ")"
        end
      end

      # @private
      class HashCollectionType < Type
        attr_accessor :key_value_pairs

        def initialize(name, key_types_or_pairs, value_types = nil)
          @name = name

          if value_types.nil?
            # New signature: (name, key_value_pairs)
            @key_value_pairs = key_types_or_pairs || []
          else
            # Old signature: (name, key_types, value_types)
            @key_value_pairs = [[key_types_or_pairs, value_types]]
          end
        end

        # Backward compatibility accessors
        def key_types
          return [] if @key_value_pairs.empty?
          @key_value_pairs.first[0] || []
        end

        def key_types=(types)
          if @key_value_pairs.empty?
            @key_value_pairs = [[types, []]]
          else
            @key_value_pairs[0][0] = types
          end
        end

        def value_types
          return [] if @key_value_pairs.empty?
          @key_value_pairs.first[1] || []
        end

        def value_types=(types)
          if @key_value_pairs.empty?
            @key_value_pairs = [[[], types]]
          else
            @key_value_pairs[0][1] = types
          end
        end

        def to_s(_singular = true)
          return "a#{name[0, 1] =~ /[aeiou]/i ? 'n' : ''} #{name}" if @key_value_pairs.empty?

          result = "a#{name[0, 1] =~ /[aeiou]/i ? 'n' : ''} #{name} with "
          parts = @key_value_pairs.map do |keys, values|
            "keys made of (" + list_join(keys.map {|t| t.to_s(false) }) +
            ") and values of (" + list_join(values.map {|t| t.to_s(false) }) + ")"
          end
          result + parts.join(" and ")
        end
      end

      # @private
      class Parser
        include CodeObjects

        TOKENS = {
          :collection_start => /</,
          :collection_end => />/,
          :fixed_collection_start => /\(/,
          :fixed_collection_end => /\)/,
          :group_start => /\[/,
          :group_end => /\]/,
          :type_name => /#{ISEP}#{METHODNAMEMATCH}|#{NAMESPACEMATCH}|#{LITERALMATCH}|\w+/,
          :symbol => /:#{METHODNAMEMATCH}/,
          :type_next => /[,]/,
          :intersect => /&/,
          :union => /\|/,
          :whitespace => /\s+/,
          :hash_collection_start => /\{/,
          :hash_collection_value => /=>/,
          :hash_collection_value_end => /;/,
          :hash_collection_end => /\}/,
          # :symbol_start => /:/,
          :parse_end => nil
        }

        # Type names known in advance to be genuinely homogeneous
        # collections, where `<...>`'s comma-separated slots really do mean
        # "any one of these". Fixed and not user-configurable - YARD has no
        # syntax for a class to declare its own `<...>` convention, so this
        # can only ever be a hardcoded, conservative list.
        UNION_COLLECTION_NAMES = %w[Array Set].freeze

        def self.parse(string)
          new(string).parse
        end

        def initialize(string)
          @scanner = StringScanner.new(string)
        end

        # @return [Array(Boolean, Array<Type>)] - finished, types
        def parse(until_tokens: [:parse_end])
          parse_until(until_tokens).first
        end

        private

        # @param slot_pipe [Boolean] whether `|` means "alternative within
        #   the current slot" (like `&`, accumulated separately and only
        #   folded in when a slot ends) rather than a synonym for `,`. Only
        #   true directly inside `(...)`, YARD's pre-existing
        #   order-dependent-list syntax: `,` means "next slot" there, so `|`
        #   can't *also* mean "next slot" without losing its own meaning -
        #   it keeps meaning "either of these", just scoped to one slot
        #   instead of the whole list. Everywhere else, `,` and `|` are
        #   pure synonyms: both simply mean "either of these" for the
        #   whole list, so either can be used and mixed freely.
        #
        # `&` (intersection) is legal anywhere a type is expected (it never
        #   needs this distinction), accumulated via
        #   `intersection_conjuncts`/{#finish_intersection}, and always
        #   binds tighter than whichever separator is active: `A & B, C` is
        #   `(A & B), C` everywhere, and `Array(A & B | C, D)` is
        #   `Array((A & B) | C, D)` - a 2-slot tuple whose first slot is
        #   `(A & B) or C`.
        #
        # `[...]` groups a union (spelled with either `,` or `|`) into a
        #   single type usable as one conjunct of an intersection at the
        #   top level, where a bare union would otherwise just add another
        #   independent top-level item instead: `[A | B] & C` groups `A`
        #   and `B` before intersecting with `C`, where `A | B & C` would
        #   parse as the two top-level items `A` and `B & C`.
        # @return [Array(Array<Type>, Symbol, Boolean)] the parsed types,
        #   the token that ended the list, and whether `|` appeared as a
        #   direct separator at this nesting level (not inside a nested
        #   list) - used by callers that need to know whether `|` was used
        #   somewhere it has no union meaning, like a non-implicit-union
        #   `<...>`
        def parse_until(until_tokens, slot_pipe: false)
          current_parsed_types = []
          type = nil
          name = nil
          finished = false
          end_token = nil
          intersection_conjuncts = []
          slot_conjuncts = []
          used_union = false
          types = parse_with_handlers do |token_type, token|
            case token_type
            when *until_tokens
              raise SyntaxError, "expecting name, got '#{token}'" if name.nil?
              type = create_type(name) unless type
              slot = finish_intersection(intersection_conjuncts, type)
              slot = finish_group(slot_conjuncts, slot) if slot_pipe
              current_parsed_types << slot
              intersection_conjuncts = []
              slot_conjuncts = []
              finished = true
              end_token = token_type
            when :type_name
              raise SyntaxError, "expecting END, got name '#{token}'" if name
              name = token
            when :intersect
              raise SyntaxError, "expecting name, got '&' at #{@scanner.pos}" if name.nil?
              type = create_type(name) unless type
              intersection_conjuncts << type
              name = nil
              type = nil
            when :type_next
              raise SyntaxError, "expecting name, got '#{token}' at #{@scanner.pos}" if name.nil?
              type = create_type(name) unless type
              slot = finish_intersection(intersection_conjuncts, type)
              slot = finish_group(slot_conjuncts, slot) if slot_pipe
              current_parsed_types << slot
              intersection_conjuncts = []
              slot_conjuncts = []
              name = nil
              type = nil
            when :union
              raise SyntaxError, "expecting name, got '|' at #{@scanner.pos}" if name.nil?
              used_union = true
              type = create_type(name) unless type
              combined = finish_intersection(intersection_conjuncts, type)
              intersection_conjuncts = []
              if slot_pipe
                slot_conjuncts << combined
              else
                current_parsed_types << combined
              end
              name = nil
              type = nil
            when :fixed_collection_start, :collection_start
              is_fixed = token_type == :fixed_collection_start
              name ||= "Array"
              nested_types, _, used_pipe = parse_until(
                [:fixed_collection_end, :collection_end, :parse_end], slot_pipe: is_fixed
              )
              type = if is_fixed
                FixedCollectionType.new(name, nested_types)
              elsif name == "Hash" && nested_types.size == 2
                # `Hash<KeyType, ValueType>` is documented as positional
                # (slot 0 = key type, slot 1 = value type), matching the
                # dedicated `Hash{K=>V}` syntax - not an implicit union.
                raise SyntaxError, "'|' has no meaning in Hash<KeyType, ValueType> - " \
                  "its parameters are positional, not a union; use ',' instead" if used_pipe
                HashCollectionType.new(name, [nested_types[0]], [nested_types[1]])
              elsif nested_types.size <= 1 || UNION_COLLECTION_NAMES.include?(name)
                # A single slot is never ambiguous (nothing to distinguish
                # union from positional with only one type), and these
                # names are known, genuinely homogeneous collections.
                CollectionType.new(name, nested_types)
              else
                # `<...>` is conventionally used both ways - a homogeneous
                # collection's element type(s), or a class's distinct
                # positional type-parameter roles - and YARD has no way to
                # know which one an arbitrary class means. Don't assert
                # union for a name we don't specifically know means that,
                # and don't silently accept '|' - which always means
                # union - somewhere it wouldn't be honored.
                raise SyntaxError, "'|' has no meaning in #{name}<...> - only Array/Set " \
                  "treat their type parameters as a union; use ',' instead" if used_pipe
                ParametrizedType.new(name, nested_types)
              end
            when :group_start
              raise SyntaxError, "'[' cannot follow a type name" if name
              nested_types, = parse_until([:group_end, :parse_end])
              type = GroupType.new(nested_types)
              name = "Group"
            when :hash_collection_start
              name ||= "Hash"
              type = parse_hash_collection(name)
            end

            [finished, current_parsed_types]
          end
          [types, end_token, used_union]
        end

        # @return [Array<Type>]
        def parse_with_handlers
          loop do
            found = false
            TOKENS.each do |token_type, match|
              # TODO: cleanup this code.
              # rubocop:disable Lint/AssignmentInCondition
              next unless (match.nil? && @scanner.eos?) || (match && token = @scanner.scan(match))
              found = true
              # @type [Array<Type>]
              finished, types = yield(token_type, token)
              return types if finished
              break
            end
            raise SyntaxError, "invalid character at #{@scanner.peek(1)}" unless found
          end
          nil
        end

        def parse_hash_collection(name)
          key_value_pairs = []
          current_keys = []
          key_name = nil
          key_type = nil
          intersection_conjuncts = []
          finished = false

          # Finalizes whatever key is pending (if any) into `current_keys`,
          # the same way `parse_until` finalizes a union member - `&` binds
          # tighter than the `,`/`|` (synonyms here, as everywhere outside
          # `(...)`) that separates keys.
          finalize_key = lambda do
            next if key_name.nil?
            key_type = create_type(key_name) unless key_type
            current_keys << finish_intersection(intersection_conjuncts, key_type)
            intersection_conjuncts = []
            key_name = nil
            key_type = nil
          end

          parse_with_handlers do |token_type, token|
            case token_type
            when :type_name
              raise SyntaxError, "expecting END, got name '#{token}'" if key_name
              key_name = token
            when :intersect
              raise SyntaxError, "expecting name, got '&' at #{@scanner.pos}" if key_name.nil?
              key_type = create_type(key_name) unless key_type
              intersection_conjuncts << key_type
              key_name = nil
              key_type = nil
            when :type_next, :union
              # ',' and '|' are synonyms here, as everywhere outside '(...)'
              raise SyntaxError, "expecting name, got '#{token}' at #{@scanner.pos}" if key_name.nil?
              finalize_key.call
            when :hash_collection_value
              # => - current keys map to the next value(s)
              finalize_key.call
              raise SyntaxError, "no keys before =>" if current_keys.empty?
              values, end_token = parse_until([:hash_collection_value_end, :hash_collection_end, :parse_end])
              key_value_pairs << [current_keys, values]
              current_keys = []
              finished = end_token != :hash_collection_value_end
            when :hash_collection_end, :parse_end
              # End of hash
              finished = true
            when :whitespace
              # Ignore whitespace
            end

            [finished, HashCollectionType.new(name, key_value_pairs)]
          end
        end

        private

        # Combines the conjuncts of an `A & B & ...` intersection with the
        # final type in the chain. Consecutive duck-types (`#foo & #bar`)
        # collapse into a single {DuckType} listing all of the methods, to
        # match the pre-existing duck-type convention; any other mix of
        # types becomes an {IntersectionType}.
        #
        # @param conjuncts [Array<Type>] the conjuncts seen so far (may be empty)
        # @param last_type [Type] the final conjunct in the chain
        # @return [Type] the combined type for this union slot
        def finish_intersection(conjuncts, last_type)
          return last_type if conjuncts.empty?
          all_types = conjuncts + [last_type]
          if all_types.all? {|t| t.is_a?(DuckType) }
            DuckType.new(all_types.map(&:name).join(' & '))
          else
            IntersectionType.new(all_types)
          end
        end

        # Combines the `|`-separated conjuncts of one order-dependent-list
        # slot (`A | B` in `Array(A | B, C)`) with the slot's final type
        # into a single {GroupType}, the same representation `[...]`
        # produces - so `Array(A | B, C)` and `Array([A | B], C)` describe
        # the same type.
        #
        # @param conjuncts [Array<Type>] the conjuncts seen so far (may be empty)
        # @param last_type [Type] the final conjunct in the slot
        # @return [Type] the combined type for this slot
        def finish_group(conjuncts, last_type)
          return last_type if conjuncts.empty?
          GroupType.new(conjuncts + [last_type])
        end

        def create_type(name)
          if name[0, 1] == ":" || (name[0, 1] =~ /['"]/ && name[-1, 1] =~ /['"]/)
            LiteralType.new(name)
          elsif name[0, 1] == "#"
            DuckType.new(name)
          else
            Type.new(name)
          end
        end

        private

        def create_type(name)
          if name[0, 1] == ":" || (name[0, 1] =~ /['"]/ && name[-1, 1] =~ /['"]/)
            LiteralType.new(name)
          elsif name[0, 1] == "#"
            DuckType.new(name)
          else
            Type.new(name)
          end
        end
      end
    end
  end
end
