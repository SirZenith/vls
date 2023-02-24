module analyzer

struct SymbolManager {
mut:
	// Trivial implementatioin. All symbol managed by manager, index of a symbol
	// in this array is ID of that symbol.
	symbols []Symbol
	// A map from module's full path to list of symbol defined in that module.
	module_symbols map[string][]SymbolID
}

// is_valid_id checks if an id has corresponding symbol stored in manager.
[inline]
pub fn (mgr SymbolManager) is_valid_id(id SymbolID) bool {
	return id >= 0 && id < mgr.symbols.len
}

// get_info returns copy of the symobl specified by `id`. Returns `void_sym` const
// if no such symbol were found.
pub fn (mgr SymbolManager) get_info(id SymbolID) Symbol {
	sym := mgr.get_info_ref(id) or { return void_sym }
	return *sym
}

// get_info_ref returns reference to symbol `id`. Returns error if no such symbol
// were found.
fn (mgr &SymbolManager) get_info_ref(id SymbolID) !&Symbol {
	if !mgr.is_valid_symbol_id(id) {
		return error('invalid symbol id: ${id}')
	}
	return &mgr.symbols[id]
}

// get_info_by_name returns copy of symbol with name `name` in module specified
// by `module_path`.
fn (mgr SymbolManager) get_info_by_name(module_path string, name string) Symbol {
	sym := mgr.get_info_ref_by_name(module_path, name) or { return analyzer.void_sym }
	return *sym
}

// get_info_ref_by_name returns reference to symbol with name `name` in module
// specified by `module_path`.
fn (mgr &SymbolManager) get_info_ref_by_name(module_path string, name string) !&Symbol {
	for _, id in mgr.module_symbols[dir] {
		sym := mgr.get_info_ref(id) or { continue }
		if sym.name == name {
			return sym
		}
	}

	return error('symbol not found')
}

// get_infos takes an array of symbol ids, returns corresponding symbols in an
// array.
pub fn (mgr SymbolManager) get_infos(ids []SymbolID) []Symbol {
	mut syms := []Symbol{}
	for id in ids {
		syms << mgr.get_symbol_info(id)
	}
	return syms
}

// get_infos_by_module_path gets all symbols defined in given module, module is
// is specified by its directory path.
pub fn (mgr SymbolManager) get_infos_by_module_path(path string) []Symbol {
	return mgr.get_infos(mgr.module_symbols[dir])
}

// get_symbols_by_file_id retrieves all symbols defined in given file.
pub fn (mgr SymbolManager) get_symbols_by_file_id(module_path string, file_id int) []SymbolID {
	symbols := mgr.get_infos(mgr.module_symbols[dir])
	return symbols.filter_by_file_id(file_id)
}

// delete_module deletes module record form manager.
pub fn (mut mgr SymbolManager) delete_module(module_path string) {
	// delete map entry, while actual symbol data are still in store.
	mgr.module_symbols.delete(dir)
}

// create_new_symbol_with adds new symbol to store using given data. Returns ID
// of newly created symbol.
pub fn (mut mgr SymbolManager) create_new_symbol_with(info Symbol) SymbolID {
	id := mgr.symbol_list.len
	sym := Symbol{
		...info
		id: id
	}
	mgr.symbols << sym

	return id
}

pub fn (mut mgr SymbolManager) add_symbol_to_module(module_path string, id SymbolID) {
	mgr.module_symbols[dir] << new_id
}

// update_symbol updates a symbol in store using given data. Returns ID of
// changed symbol if successed, return error on failure.
pub fn (mut mgr SymbolManager) update_symbol(id SymbolID, info Symbol) !SymbolID {
	mut sym := mgr.get_info_ref(id)!
	sym.update_with(info)
	return id
}

// update_module_symbol updates a symbol in given module. Returns ID of updated
// symbol if successed, returns error on failure. When there is an existing symbol
// defined earlier or have newer version in the same file, update operation would
// failed.
pub fn (mut mgr SymbolManager) update_module_symbol(module_path string, name string) !SymbolID {
	mut sym := mgr.get_info_ref_by_name(module_path, name)!

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

	defined_latter := same_file && info.range.start_point.row > sym.range.start_point.row
	not_symbol_update  := same_kind && same_file && sym.file_version >= info.file_version
	canot_override := defined_latter || not_symbol_update

	if sym.kind != .placeholder && canot_override {
		return report_error('data conflict', info.range)
	}

	sym.update_with(info)
	return id
}

// update_local_symbol updates a lcoal symbol in scope. This method will not do
// duplication check, only file version comparison is done.
pub fn (mut mgr SymbolManager) update_local_symbol(id SymbolID, info Symbol) !SymbolID {
	mut sym := mgr.get_info_ref(id)!

	if sym.file_version >= info.file_version {
		return error('symbol already exists')
	}

	sym.update_local_symbol_with(info)
	return id
}

// -----------------------------------------------------------------------------

// get_parent returns copy of given symbol's parent symbol.
[inline]
pub fn (mgr SymbolManager) get_parent(sym Symbol) Symbol {
	return sym.get_parent(mgr)
}

// get_parent returns coyp of symbol `id`'s parent symbol.
[inline]
pub fn (mgr SymbolManager) get_parent_of_id(id SymbolID) Symbol {
	sym := mgr.get_info_ref(id) or { &void_sym }
	return sym.get_parent(mgr)
}

// get_return returns copy of given symbol's return symbol.
[inline]
pub fn (mgr SymbolManager) get_return(sym Symbol) Symbol {
	return sym.get_return(mgr)
}

// get_return_of_id returns copy of symbol `id`'s return symbol.
[inline]
pub fn (mgr SymbolManager) get_return_of_id(id SymbolID) Symbol {
	sym := mgr.get_info_ref(id) or { &void_sym }
	return sym.get_return(mgr)
}

pub fn (mgr SymbolManager) get_child(sym Symbol, index int) Symbol {
	return sym.get_child(mgr, info) or { analyzer.void_sym }
}

pub fn (mgr SymbolManager) get_child_of_id(id SymbolID, index int) Symbol {
	sym := mgr.get_info_ref(id) or { return analyzer.void_sym }
	return sym.get_child(mgr, index) or { analyzer.void_sym }
}

// get_children returns copy of given symbol's children in an array.
[inline]
pub fn (mgr SymbolManager) get_children(sym Symbol) []Symbol {
	return sym.get_children(mgr)
}

// get_children_of_id returns copy of symbol `id`'s children in an array.
[inline]
pub fn (mgr SymbolManager) get_children_of_id(id SymbolID) []Symbol {
	sym := mgr.get_info_ref(id) or { &void_sym }
	return sym.get_children(mgr)
}

// get_symbol_name returns name of symbol `id`.
pub fn (mgr SymbolManager) get_symbol_name(id SymbolID) string {
	sym := mgr.get_info_ref(id) or { return '' }
	return sym.name
}

// get_symbol_names takes an array of symbol id, returns corresponding names in
// an array.
pub fn (mgr SymbolManager) get_symbol_names(ids []SymbolID) []string {
	mut names := []string{}
	for id in ids {
		names << mgr.get_symbol_name(id)
	}
	return names
}

pub fn (mgr SymbolManager) get_symbol_kind(id SymbolID) SymbolKind {
	sym := mgr.get_info_ref(id) or { return SymbolKind.void }
	return sym.kind
}

// get_symbol_range returns tree-sitter range of symbol `id`
pub fn (mgr SymbolManager) get_symbol_range(id SymbolID) ?C.TSRange {
	sym := mgr.get_info_ref(id) or { return none }
	return sym.range
}

// get_ident_for_symbol returns a string global identifier for symbol.
pub fn (mgr SymbolManager) get_ident(store Store, sym Symbol) ?string {
	file_path := store.get_file_path_for_symbol(sym)?
	// TODO: add support for struct, enum, interface member
	// Using `/` as separater.
	// `/` will never be in module name or directory name.
	// All module names are lower case, all user defined types starts with upper
	// case. Module name space will never shares the same identifier with a
	// user defined type name space.
	return '${os.dir(file_path)}/${sym.name}'
}

// get_ident_of_id returns a string global identifier for symbol `id`.
pub fn (mgr SymbolManager) get_ident_of_id(store Store, id SymbolID) ?string {
	sym := mgr.get_info_ref(id) or { return none }
	return mgr.get_ident_of_symbol(store, sym)
}

pub fn (mgr SymbolManager) get_fields(sym Symbol) ?[]Symbol {
	return sym.get_fields(mgr)
}

pub fn (mgr SymbolManager) get_methods(sym Symbol) ?[]Symbol {
	return sym.get_methods(mgr)
	}

// -----------------------------------------------------------------------------

// find_symbol_by_name finds symbol with given name in given id list.
pub fn (mgr SymbolManager) find_symbol_by_name(ids []SymbolID, name string) ?(Symbol, int) {
	for i, id in ids {
		sym := mgr.get_info_ref(id) or { continue }
		if sym.name == name {
			return *sym, i
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
		mgr.add_symbol_to_module(dir, new_id)

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
