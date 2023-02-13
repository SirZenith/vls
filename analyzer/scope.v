module analyzer

import strings

const empty_scope_id = -1

type ScopeID = int

interface ScopeInfoLoader {
	get_info(id ScopeID) ScopeTree
	get_infos(ids []ScopeID) []ScopeTree
}

pub struct ScopeTree {
	id ScopeID
mut:
	// ID of parent scrope
	parent     ScopeID = analyzer.empty_scope_id
	// IDs of child scope
	children   []ScopeID
	// IDs of symbol in this scope
	symbols    []SymbolID
	start_byte u32
	end_byte   u32
}

const empty_scope = ScopeTree{
	id: empty_scope_id
}

pub fn (scope ScopeTree) str() string {
	return if isnil(scope) { '<nil scope>' } else { scope.symbols.str() }
}

// debug_str returns detailed string for scope inspecting.
pub fn (scope ScopeTree) debug_str(loader ScopeInfoLoader, sym_loader SymbolInfoLoader, indent string) string {
	if scope.symbols.len == 0 && scope.children.len == 0 {
		return '${indent}{}'
	}

	mut builder := strings.new_builder(30)
	builder.write_string('${indent}{\n')

	for id in scope.symbols {
		sym := sym_loader.get_info(id)
		builder.write_string(sym.debug_str(sym_loader, indent + '\t'))
		builder.write_byte(`\n`)
	}

	for id in scope.children {
		child := loader.get_info(id)
		builder.write_string(child.debug_str(loader, sym_loader, indent + '\t'))
		builder.write_byte(`\n`)
	}

	builder.write_string('${indent}}')

	return builder.str()
}

// is_valid check whether a scope has valid id. If false, no operation should be
// done with this scope.
pub fn (scope ScopeTree) is_valid() bool {
	return scope.id >= 0
}

// -----------------------------------------------------------------------------

// update_with updates fields in a scope with provided data.
fn (mut scope ScopeTree) update_with(other ScopeTree) {
	scope.parent = other.parent
	scope.children = other.children.clone()
	scope.symbols = other.symbols.clone()
	scope.start_byte = other.start_byte
	scope.end_byte = other.end_byte
}

// update_parent sets parent of scope to ID.
fn (mut scope ScopeTree) update_parent(id ScopeID) {
	scope.parent = id
}

// add_child adds ID to scope's child list.
fn (mut scope ScopeTree) add_child(id ScopeID) {
	scope.children << id
}

// add_symbol adding symbol ID to a scope, this method will check for duplication
// before appending symbol.
fn (mut scope ScopeTree) add_symbol(id SymbolID) {
	scope.symbols << id
}

// update_range sets byte range of a scope with given value.
fn (mut scope ScopeTree) update_range(start_byte u32, end_byte u32) {
	scope.start_byte = start_byte
	scope.end_byte = end_byte
}

// get_parent returns a copy of scope's parent.
[inline]
pub fn (scope ScopeTree) get_parent(loader ScopeInfoLoader) ScopeTree {
	return loader.get_info(scope.parent)
}

// get_children returns copy of scope's children as an array.
[inline]
pub fn (scope ScopeTree) get_children(loader ScopeInfoLoader) []ScopeTree {
	return loader.get_infos(scope.children)
}

// get_symbols returns copy of symbols defined in current scope (child scopes
// not included) as an array.
[inline]
pub fn (scope ScopeTree) get_symbols(sym_loader SymbolInfoLoader) []Symbol {
	return sym_loader.get_infos(scope.symbols)
}

// -----------------------------------------------------------------------------

// contains checks if a given position is within the scope's range
pub fn (scope ScopeTree) contains(pos u32) bool {
	return pos >= scope.start_byte && pos <= scope.end_byte
}

// innermost returns the smallest child scope containing given range in current scope.
pub fn (scope ScopeTree) innermost(mgr ScopeManager, start_byte u32, end_byte u32) ?ScopeTree {
	children := scope.get_children(mgr)
	for child_scope in children {
		if child_scope.contains(start_byte) && child_scope.contains(end_byte) {
			return child_scope.innermost(mgr, start_byte, end_byte) or { return child_scope }
		}
	}
	return none
}

// find_or_create tries walk through scope tree to find a child scope containing
// given range. If there's no child in current scope or given range is completely
// contained in found scope, a new child scope is created for this range.
pub fn (scope ScopeTree) find_or_create(mut mgr ScopeManager, start_byte u32, end_byte u32) ScopeTree {
	mut innermost := scope.innermost(mgr, start_byte, end_byte) or {
		new_id := mgr.create_new_scope_child_for(scope.id,
			start_byte: start_byte
			end_byte: end_byte
		)
		return mgr.get_info(new_id)
	}

	if start_byte > innermost.start_byte && end_byte < innermost.end_byte {
		new_id := mgr.create_new_scope_child_for(innermost.id,
			start_byte: start_byte
			end_byte: end_byte
		)
		return mgr.get_info(new_id)
	} else {
		return innermost
	}
}

// register_symbol registers new symbol to the scope or updates existing symbol
// with given data.
fn (mut scope ScopeTree) register_symbol(mut sym_mgr SymbolManager, info Symbol) ! {
	if scope.id == empty_scope_id {
		return error('trying to register symbol in a invalid scope')
	}

	if sym, index := sym_mgr.find_symbol_by_name(scope.symbols, info.name) {
		sym_mgr.update_local_symbol(sym.id, info) or {
			pos_str := 'scope [${scope.start_byte}, ${scope.end_byte}), idx = ${index}, name="${sym.name}"'
			return error('${err}, ${pos_str}')
		}
	} else {
		new_id := sym_mgr.create_new_symbol_with(info)
		scope.symbols << new_id
	}

	if info.range.start_byte < scope.start_byte {
		scope.start_byte = info.range.start_byte
	}
}

// get_scope retrieves a symbol with given name in current scope
pub fn (scope ScopeTree) get_symbol(sym_loader SymbolInfoLoader, name string) ?Symbol {
	return if sym, _ := sym_loader.find_symbol_by_name(scope.symbols, name) {
		sym
	} else {
		none
	}
}

// remove_symbols_by_line remove all symbols fall in given range. Returns true
// if no symbol is defined directly in this scope after deleting.
fn (mut scope ScopeTree) remove_symbols_by_line(sym_loader SymbolInfoLoader, start_line u32, end_line u32) bool {
	// iterate in reverse order to ensure `delete` always delets the right index.
	for i := scope.symbols.len - 1; i >= 0; i-- {
		range := sym_loader.get_symbol_range(scope.symbols[i]) or {
			scope.symbols.delete(i)
			continue
		}

		if within_range(range, start_line, end_line) {
			scope.symbols.delete(i)
		}
	}

	return scope.symbols.len == 0
}

// remove_symbol_by_name removes the the symbol with name `name`. Returns `true`
// when such symbol is found and deleted.
fn (mut scope ScopeTree) remove_symbol_by_name(sym_loader SymbolInfoLoader, name string) bool {
	return if _, index := sym_loader.find_symbol_by_name(scope.symbols, name) {
		scope.symbols.delete(index)
		true
	} else {
		false
	}
}

// get_symbols before returns a list of symbols that are defined before
// the target byte offset
pub fn (scope ScopeTree) get_symbols_before(mgr ScopeManager, sym_loader SymbolInfoLoader, target_byte u32) []SymbolID {
	mut ids := []SymbolID{}
	mut selected_scope := scope.innermost(mgr, target_byte, target_byte) or { return ids }
	
	for {
		for id in selected_scope.symbols {
			range := sym_loader.get_symbol_range(id) or { continue }
			if range.start_byte <= target_byte && range.end_byte <= target_byte {
				ids << id
			}
		}

		selected_scope = mgr.get_parent(selected_scope)
		if selected_scope.id == empty_scope_id {
			break
		}
	}

	return ids
}

// get_symbol_with_range finds symbo with given name within specific range.
pub fn (scope ScopeTree) get_symbol_with_range(mgr ScopeManager, sym_loader SymbolInfoLoader, name string, range C.TSRange) ?Symbol {
	ids := scope.get_symbols_before(mgr, sym_loader, range.end_byte)
	return if sym, _ := sym_loader.find_symbol_by_name(ids, name) {
		sym
	} else {
		none
	}
}
