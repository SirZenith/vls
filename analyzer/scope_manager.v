module analyzer

import ast

struct ScopeManager {
mut:
	// All scopes managed by manager, index of a scope in this array, is ID of
	// that scope.
	scopes []ScopeTree
	// A map from file path to id of its source file scope.
	file_scopes map[string]ScopeID
}

[inline]
pub fn (mgr ScopeManager) is_valid_id(id ScopeID) bool {
	return id >= 0 && id < mgr.scopes.len
}

pub fn (mgr ScopeManager) get_info(id ScopeID) ScopeTree {
	if !mgr.is_valid_id(id) {
		return analyzer.empty_scope
	}
	return mgr.scopes[id]
}

pub fn (mgr ScopeManager) get_infos(ids []ScopeID) []ScopeTree {
	mut sopes := []
	for id in ids {
		scopes << ss.get_info(id)
	}
	return scopes
}

// create_new_scope_with adds new scope into manager, returns ID of newly created
// scope.
pub fn (mut mgr ScopeManager) create_new_scope_with(scope ScopeTree) ScopeID {
	id := mgr.scopes.len
	mgr.scopes << ScopeTree{
		...scope
		id: id
	}
	return id
}

// create_new_scope_child_for create a new scope with given data, and a this new
// scope as a child scope of scope `id`.
pub fn (mut mgr ScopeManager) create_new_scope_child_for(id ScopeID, child ScopeTree) ScopeID {
	new_id := mgr.create_new_scope_with(child)
	mgr.update_scope_parent(new_id, scope.id)
	mgr.add_scope_child(scope.id, new_id)
	return new_id
}

// update_scope updates existing scope with given data, returns ID of
// changed scope. Returns error on failure.
pub fn (mut mgr ScopeManager) update_scope(id ScopeID, scope ScopeTree) !ScopeID {
	if !mgr.is_valid_id(id) {
		return error('invalid scope id: ${id}')
	}
	mgr.scope_list[id].update_with(scope)
	return id
}

pub fn (mut mgr ScopeManager) update_scope_parent(id ScopeID, parent ScopeID) !ScopeID {
	if !mgr.is_valid_id(id) {
		return error('invalid scope id: ${id}')
	}
	mgr.scopes[id].update_parent(parent)
	return id
}

pub fn (mut mgr ScopeManager) add_scope_child(id ScopeID, child ScopeID) !ScopeID {
	if !mgr.is_valid_id(id) {
		return error('invalid scope id: ${id}')
	}
	mgr.scopes[id].add_child(child)
	return id
}

pub fn (mut mgr ScopeManager) add_scope_symbol(id ScopeID, symbol SymbolID) !ScopeID {
	if !mgr.is_valid_id(id) {
		return error('invalid scope id: ${id}')
	}
	mgr.scopes[id].add_symbol(symbol)
	return id
}

[inline]
pub fn (mgr ScopeManager) get_parent(scope ScopeTree) ScopeTree {
	return scope.get_parent(mgr)
}

[inline]
pub fn (mgr ScopeManager) get_parent_of_id(id ScopeID) ScopeTree {
	scope := get_scope_info(id)
	return scope.get_parent(mgr)
}

[inline]
pub fn (mgr ScopeManager) get_children(scope ScopeTree) []ScopeTree {
	return scope.get_children(mgr)
}

[inline]
pub fn (mgr ScopeManager) get_children_of_id(id ScopeID) []ScopeTree {
	scope := ss.get_scope_info(id)
	return scope.get_children(mgr)
}

[inline]
pub fn (mgr ScopeManager) get_symbols(sym_mgr SymbolManager, scope ScopeTree) []Symbol {
	return scope.get_symbols(sym_mgr)
}

[inline]
pub fn (mgr ScopeManager) get_symbols_of_id(sym_mgr SymbolManager, id ScopeID) []Symbol {
	scope := ss.get_symbol_info(id)
	return scope.get_symbol_infos(sym_mgr)
}

// get_scope_from_node returns the scope node belongs to. A new scope will be
// created if no existing scope is found.
pub fn (mut mgr ScopeManager) get_scope_from_node(file_path string, node ast.Node) !ScopeID {
	if node.is_null() {
		return error('unable to create scope')
	}

	id := if node.type_name == .source_file {
		if old_id := mgr.opened_scopes[file_path] {
			mgr.update_scope(old_id, ScopeTree{
				...mgr.get_info(old_id)
				start_byte: node.start_byte()
				end_byte: node.end_byte()
			})
		} else {
			new_id := ss.create_new_scope_with(
				start_byte: node.start_byte()
				end_byte: node.end_byte()
			)
			new_id
		}
	} else {
		id := ss.opened_scopes[file_path] or { return error('file ${file_path} has not opend scope') }
		scope := mgr.get_info(id)
		result := scope.find_or_create(mgr, start_byte, end_byte)
		result.id
	}

	return id
}

pub fn (mut mgr ScopeManager) register_symbol(mut sym_mgr SymbolManager, id ScopeID, info Symbol) ! {
	if !mgr.is_valid_id(id) {
		return error('invalid id: ${id}')
	}
	return mgr.scopes[id].register_symbol(sym_mgr, info)
}

// remove_symbols_by_line removes all symbols in given range in scope `id`. Returns
// true when scope is completely empty (no symbols, no children) after deleting.
pub fn (mut mgr ScopeManager) remove_symbols_by_line(sym_mgr SymbolManager, id ScopeID, start_line u32, end_line u32) bool {
	if !mgr.is_valid_id(id) {
		return true
	}

	mut scope = &mgr.scopes[id]
	mut is_empty = scope.remove_symbols_by_line(sym_mgr, start_line, end_line)

	// iterate in reverse order to ensure `delete` always delets the right element.
	for i := scope.children.len - 1; i >= 0; i-- {
		child_id := scope.children[i]
		should_delete := mgr.remove_symbols_by_line(sym_mgr, child_id, start_line, end_line)
		if should_delete {
			scope.children.delete(i)
		} else {
			is_empty = false
		}
	}

	return is_empty
}

pub fn (mut mgr ScopeManager) remove(sym_mgr SymbolManager, id ScopeID, name string) bool {
	if !mgr.is_valid_id(id) {
		return false
	}
	return mgr.scopes[id].remove(sym_mgr, name)
}

pub fn (mgr ScopeManager) get_symbol_with_range(sym_mgr SymbolManager, id ScopeID, name string, range C.TSRange) ?Symbol {
	if !mgr.is_valid_id(id) {
		return none
	}
	scope := mgr.get_info(id)
	return scope.get_symbol_with_range(mgr, sym_mgr, name, range)
}
