require 'sass/scss/rx'

require 'strscan'

module Sass
  module SCSS
    class Parser
      def initialize(str)
        @scanner = StringScanner.new(str)
      end

      def parse
        root = stylesheet
        expected("selector or at-rule") unless @scanner.eos?
        root
      end

      private

      include Sass::SCSS::RX

      def stylesheet
        root = Sass::Tree::RootNode.new(@scanner.string)

        s

        while child = at_rule || ruleset
          root << child
          s
        end
        root
      end

      def s
        nil while tok(S) || tok(CDC) || tok(CDO) || tok(COMMENT)
        true
      end

      def ss
        nil while tok(S) || tok(COMMENT)
        true
      end

      def at_rule
        val = str do
          return unless tok ATRULE
          ss
          # Most at-rules take expressions (e.g. @media, @import),
          # but some (e.g. @page) take selector-like arguments
          expr || selector
        end
        node = Sass::Tree::DirectiveNode.new(val.strip)

        @expected = '"{" or ";"'
        if raw '{'
          block(node)
        else
          raw! ';'
        end

        node
      end

      def operator
        # Many of these operators (all except / and ,)
        # are disallowed by the CSS spec,
        # but they're included here for compatibility
        # with some proprietary MS properties
        ss if raw('/') || raw(',') || raw(':') || raw('.') || raw('=')
        true
      end

      def unary_operator
        raw('-') || raw('+')
      end

      def property
        return unless name = tok(IDENT)
        ss
        name
      end

      def ruleset
        rules = str do
          return unless selector

          while raw ','
            ss; expr!(:selector)
          end
        end

        block!(Sass::Tree::RuleNode.new(rules.strip))
      end

      def block!(node)
        raw! '{'
        block(node)
      end

      # A block may contain declarations and/or rulesets
      def block(node)
        ss
        node << (child = declaration_or_ruleset)
        while raw(';') || (child && !child.children.empty?)
          ss
          node << (child = declaration_or_ruleset)
        end
        raw! '}'; ss
        node
      end

      # This is a nasty hack, and the only place in the parser
      # that requires backtracking.
      # The reason is that we can't figure out if certain strings
      # are declarations or rulesets with fixed finite lookahead.
      # For example, "foo:bar baz baz baz..." could be either a property
      # or a selector.
      #
      # To handle this, we simply check if it works as a property
      # (which is the most common case)
      # and, if it doesn't, try it as a ruleset.
      #
      # We could eke some more efficiency out of this
      # by handling some easy cases (first token isn't an identifier,
      # no colon after the identifier, whitespace after the colon),
      # but I'm not sure the gains would be worth the added complexity.
      def declaration_or_ruleset
        pos = @scanner.pos
        begin
          decl = declaration
        rescue Sass::SyntaxError
        end

        return decl if decl && tok?(/[;}]/)
        @scanner.pos = pos
        return ruleset
      end

      def selector
        # The combinator here allows the "> E" hack
        return unless combinator || simple_selector_sequence
        simple_selector_sequence while combinator
        true
      end

      def combinator
        tok(PLUS) || tok(GREATER) || tok(TILDE) || tok(S)
      end

      def simple_selector_sequence
        unless element_name || tok(HASH) || class_expr ||
            attrib || negation || pseudo
          # This allows for stuff like http://www.w3.org/TR/css3-animations/#keyframes-
          return expr
        end

        # The raw('*') allows the "E*" hack
        nil while tok(HASH) || class_expr || attrib ||
          negation || pseudo || raw('*')
        true
      end

      def class_expr
        return unless raw '.'
        tok! IDENT
      end

      def element_name
        res = tok(IDENT) || raw('*')
        if raw '|'
          @expected = "element name or *"
          res = tok(IDENT) || raw!('*')
        end
        res
      end

      def attrib
        return unless raw('[')
        ss
        attrib_name!; ss
        if raw('=') ||
            tok(INCLUDES) ||
            tok(DASHMATCH) ||
            tok(PREFIXMATCH) ||
            tok(SUFFIXMATCH) ||
            tok(SUBSTRINGMATCH)
          ss
          @expected = "identifier or string"
          tok(IDENT) || tok!(STRING); ss
        end
        raw! ']'
      end

      def attrib_name!
        if tok(IDENT)
          # E or E|E
          tok! IDENT if raw('|')
        elsif raw('*')
          # *|E
          raw! '|'
          tok! IDENT
        else
          # |E or E
          raw '|'
          tok! IDENT
        end
      end

      def pseudo
        return unless raw ':'
        raw ':'

        @expected = "pseudoclass or pseudoelement"
        functional_pseudo || tok!(IDENT)
      end

      def functional_pseudo
        return unless tok FUNCTION
        ss
        expr! :pseudo_expr
        raw! ')'
      end

      def pseudo_expr
        return unless tok(PLUS) || raw('-') || tok(NUMBER) ||
          tok(STRING) || tok(IDENT)
        ss
        ss while tok(PLUS) || raw('-') || tok(NUMBER) ||
          tok(STRING) || tok(IDENT)
        true
      end

      def negation
        return unless tok(NOT)
        ss
        @expected = "selector"
        element_name || tok(HASH) || class_expr || attrib || expr!(:pseudo)
      end

      def declaration
        # The raw('*') allows the "*prop: val" hack
        if raw '*'
          name = expr!(:property)
        else
          return unless name = property
        end

        raw! ':'; ss

        value = str do
          expr! :expr
          prio
        end
        Sass::Tree::PropNode.new(name, value.strip, :new)
      end

      def prio
        return unless tok IMPORTANT
        ss
      end

      def expr
        return unless term
        nil while operator && term
        true
      end

      def term
        unless tok(NUMBER) ||
            tok(URI) ||
            function ||
            tok(STRING) ||
            tok(IDENT) ||
            tok(UNICODERANGE) ||
            hexcolor
          return unless unary_operator
          @expected = "number or function"
          tok(NUMBER) || expr!(:function)
        end
        ss
      end

      def function
        return unless tok FUNCTION
        ss
        expr
        raw! ')'; ss
      end

      #  There is a constraint on the color that it must
      #  have either 3 or 6 hex-digits (i.e., [0-9a-fA-F])
      #  after the "#"; e.g., "#000" is OK, but "#abcd" is not.
      def hexcolor
        return unless tok HASH
        ss
      end

      def str
        @str = ""
        yield
        @str
      ensure
        @str = nil
      end

      EXPR_NAMES = {
        :medium => "medium (e.g. print, screen)",
        :pseudo_expr => "expression (e.g. fr, 2n+1)",
        :expr => "expression (e.g. 1px, bold)",
      }

      TOK_NAMES = Haml::Util.to_hash(
        Sass::SCSS::RX.constants.map {|c| [Sass::SCSS::RX.const_get(c), c.downcase]}).
        merge(:ident => "identifier")

      def tok?(rx)
        @scanner.match?(rx)
      end

      def expr!(name)
        (e = send(name)) && (return e)
        expected(EXPR_NAMES[name] || name.to_s)
      end

      def tok!(rx)
        (t = tok(rx)) && (return t)
        expected(TOK_NAMES[rx])
      end

      def raw!(chr)
        return true if raw(chr)
        expected(chr.inspect)
      end

      def expected(name)
        pos = @scanner.pos
        line = @scanner.string[0...pos].count("\n") + 1

        after = @scanner.string[[pos - 15, 0].max...pos].gsub(/.*\n/m, '')
        after = "..." + after if pos >= 15

        expected = @expected || name

        was = @scanner.rest[0...15].gsub(/\n.*/m, '')
        was += "..." if @scanner.rest.size >= 15
        raise Sass::SyntaxError.new(
          "Invalid CSS after #{after.inspect}: expected #{expected}, was #{was.inspect}",
          :line => line)
      end

      def tok(rx)
        res = @scanner.scan(rx)
        @expected = nil if res
        @str << res if res && @str && rx != COMMENT
        res
      end

      def raw(chr)
        res = @scanner.scan(RX.quote(chr))
        @expected = nil if res
        @str << res if res && @str
        res
      end
    end
  end
end