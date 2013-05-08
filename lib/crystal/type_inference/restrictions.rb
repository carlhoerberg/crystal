module Crystal
  class Def
    def is_restriction_of?(other, owner)
      args.zip(other.args).each do |self_arg, other_arg|
        self_type = self_arg.type || self_arg.type_restriction
        other_type = other_arg.type || other_arg.type_restriction
        return false if self_type == nil && other_type != nil
        if self_type != nil && other_type != nil
          return false unless self_type.is_restriction_of?(other_type, owner)
        end
      end
      true
    end
  end

  class Ident
    def is_restriction_of?(other, owner)
      return true if self == other

      if other.is_a?(IdentUnion)
        return other.idents.any? { |o| self.is_restriction_of?(o, owner) }
      end

      return false unless other.is_a?(Ident)

      if self_type = owner.lookup_type(names)
        other_type = owner.lookup_type(other.names)

        return other_type == nil || self_type.is_restriction_of?(other_type, owner)
      end

      false
    end
  end

  class NewGenericClass
    def is_restriction_of?(other, owner)
      return true if self == other
      return false unless other.is_a?(NewGenericClass)
      return false unless name == other.name && type_vars.length == other.type_vars.length

      0.upto(type_vars.length - 1) do |i|
        return false unless type_vars[i].is_restriction_of?(other.type_vars[i], owner)
      end

      true
    end
  end

  class Type
    def is_restriction_of?(type, owner)
      type.nil? || equal?(type) ||
        type.is_a?(UnionType) && type.types.any? { |union_type| self.is_restriction_of?(union_type, owner) } ||
        type.is_a?(HierarchyType) && self.is_subclass_of?(type.base_type) ||
        generic && container.equal?(type.container) && name == type.name && type.type_vars.values.map(&:type).compact.length == 0 ||
        parents.any? { |parent| parent.is_restriction_of?(type, owner) }
    end

    def restrict(other, owner)
      ((other.nil? || equal?(other)) && self) ||
      (other.is_a?(UnionType) && other.types.any? { |union_type| self.is_restriction_of?(union_type, owner) } && self) ||
      (other.is_a?(HierarchyType) && self.is_subclass_of?(other.base_type) && self) ||
      (generic && container.equal?(other.container) && name == other.name && !other.type_vars.values.any?(&:type) && self) ||
      (parents.first && parents.first.is_restriction_of?(other, owner) && self) ||
      nil
    end
  end

  class SelfType
    def is_restriction_of?(type, owner)
      owner.is_restriction_of?(type, owner)
    end
  end

  class UnionType
    def is_restriction_of?(type, owner)
      types.any? { |sub| sub.is_restriction_of?(type, owner) }
    end

    def restrict(type, owner)
      program.type_merge(*types.map { |sub| sub.restrict(type, owner) })
    end
  end

  class HierarchyType
    def is_restriction_of?(other, owner)
      other.is_subclass_of?(self.base_type) || self.base_type.is_subclass_of?(other)
    end

    def restrict(other, owner)
      if equal?(other)
        self
      elsif other.is_a?(UnionType)
        program.type_merge *other.types.map { |t| self.restrict(t, owner) }
      elsif other.is_a?(HierarchyType)
        result = base_type.restrict(other.base_type, owner) || other.base_type.restrict(base_type, owner)
        result ? result.hierarchy_type : nil
      elsif other.is_subclass_of?(self.base_type)
        other.hierarchy_type
      elsif self.base_type.is_subclass_of?(other)
        self
      else
        nil
      end
    end

    def is_subclass_of?(other)
      binding.pry
    end
  end
end