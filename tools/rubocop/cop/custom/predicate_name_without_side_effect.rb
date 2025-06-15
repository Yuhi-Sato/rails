module RuboCop
  module Cop
    module Custom
      # Enhanced version of Naming/PredicateName that skips methods
      # containing side effects unrelated to the returned value.
      #
      # This is a simplified heuristic implementation based on the idea that
      # predicate methods should be free of side effects. When a method body
      # contains statements that do not contribute to the final boolean result,
      # the cop will consider it not a predicate.
      class PredicateNameWithoutSideEffect < RuboCop::Cop::Naming::PredicateName
        def on_def(node)
          return if side_effect_method?(node)

          super
        end
        alias on_defs on_def

        private

        def side_effect_method?(node)
          body = node.body
          return false unless body

          statements = body.begin_type? ? body.children : [body]
          return false if statements.size <= 1

          last = statements.last
          used_vars = variables_in(last)

          statements[0..-2].any? do |stmt|
            if assignment_to_used_var?(stmt, used_vars)
              used_vars.concat(variables_assigned(stmt))
              false
            else
              true
            end
          end
        end

        def variables_in(node)
          node.each_descendant(:lvar, :ivar, :cvar, :gvar).map(&:value)
        end

        def variables_assigned(node)
          case node.type
          when :lvasgn, :ivasgn, :cvasgn, :gvasgn
            [node.children.first]
          when :masgn
            node.lhs.children.map { |n| n.children.first }
          else
            []
          end
        end

        def assignment_to_used_var?(node, vars)
          case node.type
          when :lvasgn, :ivasgn, :cvasgn, :gvasgn
            vars.include?(node.children.first)
          when :masgn
            node.lhs.children.any? { |n| vars.include?(n.children.first) }
          else
            false
          end
        end
      end
    end
  end
end
