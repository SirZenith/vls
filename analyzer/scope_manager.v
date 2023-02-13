module analyzer

import ast

struct ScopeManager {
mut:
	// Trivial implementation. All scopes managed by manager, index of a scope
	// in this array, is ID of that scope.
	scopes []ScopeTree
	// A map from file path to id of its source file scope.
	file_scopes map[string]ScopeID
}

// is_valid_id checks if a ID has corresponding symbol in manager.
[inline]
pub fn (mgr ScopeManager) is_valid_id(id ScopeID) bool {
	return id >= 0 && id < mgr.scopes.len
}

// get_info returns a copy of scope specified by ID. If no scope is found, an
// `empty_scope` const is returned.
pub fn (mgr ScopeManager) get_info(id ScopeID) ScopeTree {
	if !mgr.is_valid_id(id) {
		return analyzer.empty_scope
	}
	return mgr.scopes[id]
}

// get_info_ref returns a reference to sope specified by ID. If not scope is found
// an error is returned.
fn (mgr &ScopeManager) get_info_ref(id ScopeID) !&ScopeTree {
	if !mgr.is_valid_id(id) {
		return error('invalid id: ${id}')
	}
	return &mgr.scopes[id]
}

// get_infos returns a array of copy for given ID list.
pub fn (mgr ScopeManager) get_infos(ids []ScopeID) []ScopeTree {
	mut scopes := []ScopeTree{}
	for id in ids {
		scopes << mgr.get_info(id)
	}
	return scopes
}

// get_file_scope_id returns file scope id for given file. Returns `none` if such
// file were never opened.
pub fn (mgr ScopeManager) get_file_scope_id(file_path string) ?ScopeID {
	if file_path !in mgr.file_scopes {
		return none
	}
	return mgr.file_scopes[file_path]
}

// get_file_scope returns a copy of file scope specified by `file_path`. Returns
// `none` if such file were never opened.
pub fn (mgr ScopeManager) get_file_scope(file_path string) ?ScopeTree {
	id := mgr.get_file_scope_id(file_path)?
	return mgr.get_info(id)
}

// create_new_scope_with adds new scope into manager with given data, returns ID
// of newly created scope.
pub fn (mut mgr ScopeManager) create_new_scope_with(scope ScopeTree) ScopeID {
	id := mgr.scopes.len
	mgr.scopes << ScopeTree{
		...scope
		id: id
	}
	return id
}

// create_new_scope_child_for create a new scope with given data, and a this new
// scope as a child scope of scope `id`. Returns `empty_scope_id` const on failure.
pub fn (mut mgr ScopeManager) create_new_scope_child_for(id ScopeID, child ScopeTree) ScopeID {
	if !mgr.is_valid_id(id) {
		return analyzer.empty_scope_id
	}
	new_id := mgr.create_new_scope_with(child)
	mgr.update_scope_parent(new_id, id) or {}
	mgr.add_scope_child(id, new_id) or {}
	return new_id
}

// update_scope updates existing scope with given data, returns ID of changed
// scope. Returns error if target scope were not found.
pub fn (mut mgr ScopeManager) update_scope(id ScopeID, other ScopeTree) !ScopeID {
	mut scope := mgr.get_info_ref(id)!
	scope.update_with(other)
	return id
}

// update_scope_parent set parent scope of scope `id` to `parent_id`, returns ID
// of modified scope. Returns error if target scope were not found.
pub fn (mut mgr ScopeManager) update_scope_parent(id ScopeID, parent_id ScopeID) !ScopeID {
	mut scope := mgr.get_info_ref(id)!
	scope.update_parent(parent_id)
	return id
}

// add_scope_child adds scope ID `child_id` to to child list of scope `id`, returns
// ID of modified scope. Returns error if target scope were not found.
pub fn (mut mgr ScopeManager) add_scope_child(id ScopeID, child_id ScopeID) !ScopeID {
	mut scope := mgr.get_info_ref(id)!
	scope.add_child(child_id)
	return id
}

// add_scope_symbol adds a symbol `symbol_id` to scope `id`, returns ID of modified
// scope. Returns error if target scope were not found.
pub fn (mut mgr ScopeManager) add_scope_symbol(id ScopeID, symbol_id SymbolID) !ScopeID {
	mut scope := mgr.get_info_ref(id)!
	scope.add_symbol(symbol_id)
	return id
}

// get_parent returns a copy of `scope`'s parent scope.
[inline]
pub fn (mgr ScopeManager) get_parent(scope ScopeTree) ScopeTree {
	return scope.get_parent(mgr)
}

// get_parent_of_id returns copy of scope `id`'s parent scope.
[inline]
pub fn (mgr ScopeManager) get_parent_of_id(id ScopeID) ScopeTree {
	scope := mgr.get_info_ref(id) or { &analyzer.empty_scope }
	return scope.get_parent(mgr)
}

// get_children returns copy of `scope`'s children in an array.
[inline]
pub fn (mgr ScopeManager) get_children(scope ScopeTree) []ScopeTree {
	return scope.get_children(mgr)
}

// get_children_of_id returns copy of scope `id`'s children in an array.
[inline]
pub fn (mgr ScopeManager) get_children_of_id(id ScopeID) []ScopeTree {
	scope := mgr.get_info_ref(id) or { &analyzer.empty_scope }
	return scope.get_children(mgr)
}

// get_symbols returns copy of symbols defined in given scope in an array.
[inline]
pub fn (mgr ScopeManager) get_symbols(sym_loader SymbolInfoLoader, scope ScopeTree) []Symbol {
	return scope.get_symbols(sym_loader)
}

// get_symbols returns copy of symbols defined  in scope `id` in an array.
[inline]
pub fn (mgr ScopeManager) get_symbols_of_id(sym_loader SymbolInfoLoader, id ScopeID) []Symbol {
	scope := mgr.get_info_ref(id) or { &analyzer.empty_scope }
	return scope.get_symbols(sym_loader)
}

// get_scope_from_node returns the scope node belongs to. A new scope will be
// created if no existing scope is found.
pub fn (mut mgr ScopeManager) get_scope_from_node(file_path string, node ast.Node) !ScopeID {
	if node.is_null() {
		return error('unable to create scope')
	}

	start_byte, end_byte := node.start_byte(), node.end_byte()
	id := if node.type_name == .source_file {
		if old_id := mgr.get_file_scope_id(file_path) {
			mgr.update_scope(old_id, ScopeTree{
				...mgr.get_info(old_id)
				start_byte: start_byte
				end_byte: end_byte
			})!
		} else {
			mgr.create_new_scope_with(
				start_byte: start_byte
				end_byte: end_byte
			)
		}
	} else {
		scope := mgr.get_file_scope(file_path) or { return error('file ${file_path} has not opend scope') }
		result := scope.find_or_create(mut mgr, start_byte, end_byte)
		result.id
	}

	return id
}

// register_symbol adds a symbol ID to scope `id`.
pub fn (mut mgr ScopeManager) register_symbol(mut sym_mgr SymbolManager, id ScopeID, info Symbol) ! {
	mut scope := mgr.get_info_ref(id)!
	return scope.register_symbol(mut sym_mgr, info)
}

// remove_symbols_by_line removes all symbols in given range in scope `id`. Returns
// true when scope is completely empty (no symbols, no children) after deleting.
pub fn (mut mgr ScopeManager) remove_symbols_by_line(sym_loader SymbolInfoLoader, id ScopeID, start_line u32, end_line u32) bool {
	if !mgr.is_valid_id(id) {
		return true
	}

	mut scope := mgr.get_info_ref(id) or { return true }
	mut is_empty := scope.remove_symbols_by_line(sym_loader, start_line, end_line)

	// iterate in reverse order to ensure `delete` always delets the right element.
	for i := scope.children.len - 1; i >= 0; i-- {
		child_id := scope.children[i]
		should_delete := mgr.remove_symbols_by_line(sym_loader, child_id, start_line, end_line)
		if should_delete {
			scope.children.delete(i)
		} else {
			is_empty = false
		}
	}

	return is_empty
}

// remove_symbol_by_name removes a symbol with name `name` from scope `id`. Returns
// `true` when such symbol is found and deleted.
pub fn (mut mgr ScopeManager) remove_symbol_by_name(sym_mgr SymbolManager, id ScopeID, name string) bool {
	mut scope := mgr.get_info_ref(id) or { return false }
	return scope.remove_symbol_by_name(sym_mgr, name)
}

// get_symbol_with_range finds symbo with name in within specific range.
pub fn (mgr ScopeManager) get_symbol_with_range(sym_mgr SymbolManager, id ScopeID, name string, range C.TSRange) ?Symbol {
	scope := mgr.get_info_ref(id) or { return none }
	return scope.get_symbol_with_range(mgr, sym_mgr, name, range)
}
