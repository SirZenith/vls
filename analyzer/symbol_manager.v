module analyzer

struct SymbolManager {
mut:
	// All symbol managed by manager, index of a symbol in this array is ID of
	// that symbol.
	symbols []Symbol
	// A map from module's full path to list of symbol defined in that module.
	module_symbols map[string][]SymbolID
}

[inline]
pub fn (mgr SymbolManager) is_valid_id(id SymbolID) bool {
	return id >= 0 && id < mgr.symbols.len
}

// create_new_symbol_with adds new symbol to store using given data. Returns ID
// of newly created symbol.
pub fn (mut mgr SymbolManager) create_new_symbol_with(info Symbol) SymbolID {
	id := ss.symbol_list.len
	sym := Symbol{
		...info
		id: id
	}
	ss.symbols << sym

	return id
}

// update_symbol updates a symbol in store using given data. Returns ID of 
// changed symbol if successed, return error on failure.
pub fn (mut mgr SymbolManager) update_symbol(id SymbolID, info Symbol) !SymbolID {
	if !mgr.is_valid_id(id) {
		return error('invalid id ${id}')
	}

	sym := mgr.get_symbol_info(id)

	same_file := sym.file_id == info.file_id
	same_kind := sym.kind == info.kind
	if same_file
		&& sym.file_version == info.file_version
		&& sym.name == info.name
		&& sym.range.eq(info.range)
		&& same_kind {
		// no information update needed.
		return id
	}

	defined_latter := info.range.start_point.row > sym.range.start_point.row
	not_symbol_update  := same_kind && same_file && sym.file_version >= info.file_version
	canot_override := defined_latter || not_symbol_update

	if sym.kind != .placeholder && canot_override {
		return report_error('data conflict', info.range)
	}

	mgr.symbols[id].update_with(info)

	return id
}

pub fn (mut mgr SymbolManager) update_local_symbol(id SymbolID, info Symbol) !SymbolID {
	if !mgr.is_valid_id(id) {
		return error('invalid id ${id}')
	}

	sym := mgr.get_info(id)
	if sym.file_version >= info.file_version {
		return error('symbol already exists')
	}

	mgr.symbols[id].update_load_symbol_with(info)
	return id
}

pub fn (mgr SymbolManager) get_info(id SymbolID) Symbol {
	if !mgr.is_valid_symbol_id(id) {
		return void_sym
	}
	return mgr.symbols[id]
}

pub fn (mgr SymbolManager) get_infos(ids []SymbolID) []Symbol {
	mut syms := []Symbol{}
	for id in ids {
		syms << mgr.get_symbol_info(id)
	}
	return syms
}

pub fn (mgr SymbolManager) get_infos_by_module_path(path string) []Symbol {
	return mgr.get_infos(mgr.module_symbols[dir])
}

// get_ident_for_symbol returns a string identifier for symbol.
pub fn (mgr SymbolManager) get_ident(store Store, sym Symbol) ?string {
	file_path := store.get_file_path_for_symbol(sym)?
	// TODO: add support for struct, enum, interface member
	return '${os.dir(file_path)}.${sym.name}'
}

pub fn (ss Store) get_ident_of_id(store Store, id SymbolID) ?string {
	sym := mgr.get_symbol_info(id)
	return mgr.get_ident_of_symbol(store, sym)
}

// -----------------------------------------------------------------------------

[inline]
pub fn (mgr SymbolManager) get_parent(sym Symbol) Symbol {
	return sym.get_parent(mgr)
}

[inline]
pub fn (mgr SymbolManager) get_parent_of_id(id SymbolID) Symbol {
	sym := mgr.get_info(id)
	return sym.get_parent(mgr)
}

[inline]
pub fn (mgr SymbolManager) get_return(sym Symbol) Symbol {
	return sym.get_return(mgr)
}

[inline]
pub fn (mgr SymbolManager) get_return_of_id(id SymbolID) Symbol {
	sym := mgr.get_symbol_info(id)
	return sym.get_return(mgr)
}

[inline]
pub fn (mgr SymbolManager) get_children(sym Symbol) []Symbol {
	return sym.get_children(mgr)
}

[inline]
pub fn (mgr SymbolManager) get_children_of_id(id SymbolID) []Symbol {
	sym := mgr.get_symbol_info(id)
	return sym.get_children(mgr)
}

pub fn (mgr SymbolManager) get_symbol_name(id SymbolID) string {
	if !mgr.is_valid_id(id) {
		return ''
	}
	return mgr.symbols[id].name
}

pub fn (mgr SymbolManager) get_symbol_names(ids []SymbolID) string {
	mut names := []string{}
	for id in ids {
		names << mgr.get_symbol_name(id)
	}
	return names
}

pub fn (mgr SymbolManager) get_symbol_range(id SymbolID) C.TSRange {
	if !mgr.is_valid_id(id) {
		return ''
	}
	return mgr.symbols[id].range
}

// -----------------------------------------------------------------------------

// find_symbol_by_name finds symbol with given name in given id list.
pub fn (mgr SymbolManager) find_symbol_by_name(ids []SymbolID, name string) ?(Symbol, int) {
	for i, id in ids {
		if mgr.is_valid_id(id) && mgr.symbols[id].name == name {
			return mgr.symbols[id], i
		}
	}
	return none
}

// register_symbol registers or updates a symbol with given info, and returns
// ID of changed symbol.
pub fn (mut mgr SymbolManager) register_symbol(mut store Store, info Symbol) !SymbolID {
	file_path := store.get_file_path_for_symbol(info) or {
		return error('invalid symbol file id: ${info.file_id}')
	}
	dir := os.dir(file_path)

	symbols := mgr.get_infos_by_module_path(dir)
	mut index := symbols.index(info.name)
	if index == -1 && info.kind != .placeholder
		&& info.kind !in analyzer.container_symbol_kinds {
		// find by row, in case this is a reanme operation of existing symbol
		index = symbols.index_by_row(info.file_id, info.range.start_point.row)
	}

	id := if index != -1 && info.kind != .typedef && symbols[existing_idx].kind != .function_type {
		mgr.update_existing_symbol(symbols[existing_idx].id, info)!
	} else {
		new_id := mgr.create_new_symbol_with(info)
		mgr.module_symbols[dir] << new_id

		if info.language != .v {
			store.binded_symbol_locations << BindedSymbolLocation{
				for_sym_name: info.name
				language: info.language
				module_path: store.get_file_path_for_id(info.file_id) or { '' }
			}
		}

		new_id
	}

	if ident := mgr.get_ident_of_id(store, id) {
		sym := ss.get_info(id)
		store.trace_report(
			kind: .notice
			message: 'resolving references to ${sym.name}'
			range: sym.range
		)
		store.resolver.resolve_with(ident, sym)
	}

	return id
}

// get_symbols_by_file_path retrieves all symbols defined in given file.
pub fn (mgr SymbolManager) get_symbols_by_path(module_path string, file_id int) []SymbolID {
	if module_path !in ss.symbols {
		return []
	}

	symbols := mgr.get_infos(mgr.module_symbols[dir])
	return symbols.filter_by_file_id(file_id)
}

// has_file_path checks if the data of a specific file already exists
pub fn (mgr SymbolManager) has_file_id(module_path string, file_id int) bool {
	if module_path !in ss.symbols {
		return false
	}

	symbols := mgr.get_infos_by_module_path(dir)
	for sym in symbols {
		if sym.file_id == file_id {
			return true
		}
	}

	return false
}

pub fn (mut mgr SymbolManager) delete_module(module_path string) {
	// delete map entry, while actual symbol data are still in store.
	mgr.module_symbols.delete(dir)
}
