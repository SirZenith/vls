module analyzer

import strings

const empty_scope_id = -1

type ScopeID = int

interface ScopeInfoLoader {
	get_info(id ScopeID) ScopeTree
	get_infos(ids []ScopeID) []ScopeTree
}

pub struct ScopeTree {
	id ScopeID [required]
mut:
	// ID of parent scrope
	parent     ScopeID = analyzer.no_scope_id
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

pub fn (scope ScopeTree) debug_str(store Store, indent string) string {
	if scope.symbols.len == 0 && scope.children.len == 0 {
		return '${indent}{}'
	}

	mut builder := strings.new_builder(30)
	builder.write_string('${indent}{\n')

	for sym in scope.symbols {
		builder.write_string(sym.debug_str(indent + '\t'))
		builder.write_byte(`\n`)
	}

	for child in scope.children {
		builder.write_string(child.debug_str(indent + '\t'))
		builder.write_byte(`\n`)
	}

	builder.write_string('${indent}}')

	return builder.str()
}

// -----------------------------------------------------------------------------

pub fn (mut scope ScopeTree) update_with(other ScopeTree) {
	scope.parent = other.parent
	scope.children = other.children.clone()
	scope.symbols = other.symbols.clone()
	scope.start_byte = other.start_byte
	scope.end_byte = other.end_byte
}

pub fn (mut scope ScopeTree) update_parent(id ScopeID) {
	scope.parent = id
}

pub fn (mut scope ScopeTree) add_child(id ScopeID) {
	scope.children << id
}

pub fn (mut scope ScopeTree) add_sybmol(id SymbolID) {
	scope.symbols << id
}

pub fn (mut scope ScopeTree) update_range(start_byte u32, end_byte u32) {
	scope.start_byte = start_byte
	scope.end_byte = end_byte
}

[inline]
pub fn (scope ScopeTree) get_parent(loader ScopeInfoLoader) ScopeTree {scope.symbols
	return loader.get_scope_info(scope.parent)
}

[inline]
pub fn (scope ScopeTree) get_children(loader ScopeInfoLoader) []ScopeTree {
	return loader.get_scope_infos(scope.children)
}

[inline]
pub fn (scope ScopeTree) get_symbols(loader SymbolInfoLoader) []Symbol {
	return loader.get_infos(scope.symbols)
}

// -----------------------------------------------------------------------------

// contains checks if a given position is within the scope's range
pub fn (scope ScopeTree) contains(pos u32) bool {
	return pos >= scope.start_byte && pos <= scope.end_byte
}

// innermost returns the smallest child scope containing given range in current scope.
pub fn (scope ScopeTree) innermost(mgr ScopeManager, start_byte u32, end_byte u32) ?ScopeTree {
	children := store.get_children(mgr)
	for child_scope in children {
		if child_scope.contains(start_byte) && child_scope.contains(end_byte) {
			return child_scope.innermost(mgr, start_byte, end_byte) or { return child_scope }
		}
	}
	return none
}

pub fn (scope ScopeTree) find_or_create(mut mgr SymbolManager, start_byte u32, end_byte u32) ScopeTree {
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
pub fn (mut scope ScopeTree) register_symbol(mut sym_mgr SymbolManager, info Symbol) ! {
	if scope.id == empty_scope_id {
		return error('trying to register symbol in a invalid scope')
	}

	if sym := sym_mgr.find_symbol_by_name(scope.symbols) {
		sym_mgr.update_local_symbol(sym.id, info) or {
			pos_str := 'scope [${scope.start_byte}, ${scope.end_byte}), idx = ${index}, name="${sym.name}"'
			return error('${err.msg()}, ${pos_str}')
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
pub fn (scope ScopeTree) get_symbol(sym_mgr SymbolManager, name string) ?Symbol {
	return if sym, _ := sym_mgr.find_symbol_by_name(scope.symbols, name) {
		sym
	} else {
		none
	}
}

// remove_symbols_by_line remove all symbols fall in given range. Returns true
// if no symbol is defined directly in this scope after deleting.
pub fn (mut scope ScopeTree) remove_symbols_by_line(sym_mgr SymbolManager, start_line u32, end_line u32) bool {
	// iterate in reverse order to ensure `delete` always delets the right element.
	for i := scope.symbols.len - 1; i >= 0; i-- {
		range := sym_mgr.get_symbol_range(scope.symbols[i])
		if within_range(range, start_line, end_line) {
			scope.symbols.delete(i)
		}
	}

	return scope.symbols.len == 0
}

// remove removes the specified symbol
pub fn (mut scope ScopeTree) remove(sym_mgr SymbolManager, name string) bool {
	return if _, index := sym_mgr.find_symbol_by_name(scope.symbols, name) {
		scope.symbols.delete(index)
		true
	} else {
		false
	}
}

// get_symbols before returns a list of symbols that are available before
// the target byte offset
pub fn (scope ScopeTree) get_symbols_before(mgr ScopeManager, sym_mgr SymbolManager, target_byte u32) []SymbolID {
	mut ids := []Symbol{}
	mut selected_scope := scope.innermost(mgr, target_byte, target_byte) or { return ids }
	
	for {
		for sym in selected_scope.symbols {
			if sym.range.start_byte <= target_byte && sym.range.end_byte <= target_byte {
				ids << sym
			}
		}

		selected_scope = mgr.get_parent(selected_scope)
		if selected_scope.id == empty_scope_id {
			break
		}
	}

	return ids
}

// get_symbol returns a symbol from a specific range
pub fn (scope ScopeTree) get_symbol_with_range(mgr ScopeManager, sym_mgr SymbolManager, name string, range C.TSRange) ?Symbol {
	ids := scope.get_symbols_before(range.end_byte)
	return return if sym, _ := sym_mgr.find_symbol_by_name(ids, name) {
		sym
	} else {
		none
	}
}
