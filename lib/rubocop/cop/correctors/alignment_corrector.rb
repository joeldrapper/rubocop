# frozen_string_literal: true

module RuboCop
  module Cop
    # This class does autocorrection of nodes that should just be moved to
    # the left or to the right, amount being determined by the instance
    # variable column_delta.
    class AlignmentCorrector
      extend RangeHelp
      extend Alignment

      class << self
        attr_reader :processed_source

        def correct(corrector, processed_source, node, column_delta)
          return unless node

          @processed_source = processed_source

          expr = node.respond_to?(:loc) ? node.source_range : node
          return if block_comment_within?(expr)

          taboo_ranges = inside_string_ranges(node)

          if using_tabs?
            correct_tabs(corrector, expr, column_delta, taboo_ranges)
          else
            each_line(expr) do |line_begin_pos|
              autocorrect_line(corrector, line_begin_pos, expr, column_delta, taboo_ranges)
            end
          end
        end

        def align_end(corrector, processed_source, node, align_to)
          @processed_source = processed_source
          whitespace = whitespace_range(node)
          column = alignment_column(align_to)
          indentation = indentation_string(column)

          if whitespace.source.strip.empty?
            corrector.replace(whitespace, indentation)
          else
            corrector.insert_after(whitespace, "\n#{indentation}")
          end
        end

        private

        def autocorrect_line(corrector, line_begin_pos, expr, column_delta,
                             taboo_ranges)
          range = calculate_range(expr, line_begin_pos, column_delta)
          # We must not change indentation of heredoc strings or inside other
          # string literals
          return if taboo_ranges.any? { |t| within?(range, t) }

          if column_delta.positive? && range.resize(1).source != "\n"
            corrector.insert_before(range, ' ' * column_delta)
          elsif /\A[ \t]+\z/.match?(range.source)
            corrector.remove(range)
          end
        end

        # rubocop:disable Metrics
        def correct_tabs(corrector, expr, column_delta, taboo_ranges)
          width = tab_indentation_width
          # Only correct when column_delta is a multiple of the indentation
          # width. Non-multiples arise from mixed tabs/spaces and would cause
          # oscillation between passes (infinite loop).
          return unless (column_delta % width).zero?

          tab_delta = column_delta / width
          source = processed_source.buffer.source

          each_line(expr) do |line_begin_pos|
            line_start = line_start_pos(source, line_begin_pos)
            line_end = source.index("\n", line_begin_pos) || source.length
            prefix = source[line_start...line_begin_pos]
            whitespace_start = /\A[ \t]*\z/.match?(prefix) ? line_start : line_begin_pos
            leading_ws = source[whitespace_start...line_end][/\A[ \t]*/]
            next if leading_ws.empty? && tab_delta.negative?

            ws_range = range_between(whitespace_start, whitespace_start + leading_ws.length)
            next if taboo_ranges.any? { |t| within?(ws_range, t) }

            current_tabs = ((leading_ws.count("\t") * width) + leading_ws.count(' ')) / width
            new_tabs = [current_tabs + tab_delta, 0].max
            new_ws = "\t" * new_tabs

            corrector.replace(ws_range, new_ws) unless leading_ws == new_ws
          end
        end
        # rubocop:enable Metrics

        def line_start_pos(source, pos)
          return 0 if pos.zero?

          newline = source.rindex("\n", pos - 1)
          newline ? newline + 1 : 0
        end

        def tab_indentation_width
          config = processed_source.config

          config.for_cop('Layout/IndentationStyle')&.[]('IndentationWidth') ||
            config.for_cop('Layout/IndentationWidth')&.[]('Width') ||
            2
        end

        def inside_string_ranges(node)
          return [] unless node.is_a?(Parser::AST::Node)

          node.each_node(:any_str).filter_map { |n| inside_string_range(n) }
        end

        def inside_string_range(node)
          loc = node.location

          if node.heredoc?
            loc.heredoc_body.join(loc.heredoc_end)
          elsif delimited_string_literal?(node)
            loc.begin.end.join(loc.end.begin)
          end
        end

        # Some special kinds of string literals are not composed of literal
        # characters between two delimiters:
        # - The source map of `?a` responds to :begin and :end but its end is
        #   nil.
        # - The source map of `__FILE__` responds to neither :begin nor :end.
        def delimited_string_literal?(node)
          node.loc?(:begin) && node.loc?(:end)
        end

        def block_comment_within?(expr)
          processed_source.comments.select(&:document?).any? do |c|
            within?(c.source_range, expr)
          end
        end

        def calculate_range(expr, line_begin_pos, column_delta)
          return range_between(line_begin_pos, line_begin_pos) if column_delta.positive?

          starts_with_space = expr.source_buffer.source[line_begin_pos].start_with?(' ')

          if starts_with_space
            range_between(line_begin_pos, line_begin_pos + column_delta.abs)
          else
            range_between(line_begin_pos - column_delta.abs, line_begin_pos)
          end
        end

        def each_line(expr)
          line_begin_pos = expr.begin_pos
          expr.source.each_line do |line|
            yield line_begin_pos
            line_begin_pos += line.length
          end
        end

        def whitespace_range(node)
          begin_pos = node.loc.end.begin_pos

          range_between(begin_pos - node.loc.end.column, begin_pos)
        end

        def alignment_column(align_to)
          if !align_to
            0
          elsif align_to.respond_to?(:loc)
            align_to.source_range.column
          else
            align_to.column
          end
        end

        def indentation_string(column)
          if using_tabs?
            "\t" * column
          else
            ' ' * column
          end
        end

        def using_tabs?
          config = processed_source.config
          indentation_style = config.for_cop('Layout/IndentationStyle')['EnforcedStyle']
          indentation_style == 'tabs'
        end
      end
    end
  end
end
