module analyzer

import strings

// it should be imported just to have those C type symbols available
// import tree_sitter
// import os

// pub interface ISymbol {
// 	str() string
// mut:
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (isym ISymbol) root() &Symbol {
// 	if isym is Symbol {
// 		return isym
// 	} else if isym.parent_sym is Symbol {
// 		return isym.parent_sym
// 	}

// 	return isym.parent_sym.root()
// }

// TODO: From ref to chan_, use interface

pub enum SymbolKind {
	void
	placeholder
	ref
	array_
	map_
	multi_return
	optional
	result
	chan_
	variadic
	function
	struct_
	enum_
	typedef
	interface_
	field
	embedded_field
	variable
	sumtype
	function_type
	never
}

pub fn (kind SymbolKind) str() string {
	return match kind {
		.void { 'void' }
		.placeholder { 'placeholder' }
		.ref { 'ref' }
		.array_ { 'array' }
		.map_ { 'map' }
		.multi_return { 'multi_return' }
		.optional { 'optional' }
		.result { 'result' }
		.chan_ { 'chan' }
		.variadic { 'variadic' }
		.function { 'function' }
		.struct_ { 'struct' }
		.enum_ { 'enum' }
		.typedef { 'typedef' }
		.interface_ { 'interface' }
		.field { 'field' }
		.embedded_field { 'embedded_field' }
		.variable { 'variable' }
		.sumtype { 'sumtype' }
		.function_type { 'function_type' }
		.never { 'never' }
	}
}

pub enum SymbolLanguage {
	c
	js
	v
}

// pub enum Platform {
// 	auto
// 	ios
// 	macos
// 	linux
// 	windows
// 	freebsd
// 	openbsd
// 	netbsd
// 	dragonfly
// 	js
// 	android
// 	solaris
// 	haiku
// 	cross
// }

pub enum SymbolAccess {
	private
	private_mutable
	public
	public_mutable
	global
}

pub fn (sa SymbolAccess) str() string {
	return match sa {
		.private { '' }
		.private_mutable { 'mut ' }
		.public { 'pub ' }
		.public_mutable { 'pub mut ' }
		.global { '__global ' }
	}
}

pub const void_sym_id = -1

pub const void_sym = Symbol{
	id: void_sym_id
	name: 'void'
	kind: .void
	file_id: -1
	file_version: 0
	is_top_level: true
}

pub const void_sym_arr = [void_sym]

type SymbolID = int

interface SymbolInfoLoader {
	// get_info returns symbol data for given ID.
	get_info(id SymbolID) Symbol
	// get_infos returns symbol data for all given IDs in an array.
	get_infos(ids []SymbolID) []Symbol
	// find_symbol_by_name looks for symbol with specific name in given ID list.
	// returns symbol data and its index in ID list, else returns `none`.
	find_symbol_by_name(ids []SymbolID, name string) ?(Symbol, int)
	// get_symbol_name returns symbol name for given ID, return empty string if
	// no such symbol is found.
	get_symbol_name(id SymbolID) string
	// get_symbol_names returns an array of symbol name for given id list. Emtpy
	// string in returned array corresponding symbol for an ID is not found.
	get_symbol_names(ids []SymbolID) []string
	// get_symbol_range returns tree-sitter range of symbol specified by ID. `none`
	// is returned when no such symbol is found.
	get_symbol_range(id SymbolID) ?C.TSRange
}

pub struct Symbol {
	id SymbolID = analyzer.void_sym_id
pub mut:
	name                    string
	kind                    SymbolKind   // see SymbolKind
	access                  SymbolAccess // see SymbolAccess
	range                   C.TSRange
	language                SymbolLanguage = .v
	is_top_level            bool           [required]
	is_const                bool
	generic_placeholder_len int
	interface_children_len  int
	// Id of file in which this symbol is defined
	file_id                 int            [required]
	// File version when the symbol was registered
	file_version            int            [required]
	scope                   ScopeID
	// Lines of docstring comment
	docstrings              []string
	// Parent symbol is used to represent:
	//
	// - original type of a type alias
	// - receiver type, if a function symbol is a method
	// - inner type of a reference type
	// - inner type of a option/result type
	parent SymbolID = analyzer.void_sym_id
	// Return symbol is used to repreent:
	//
	// - return type of function, may be a symbol of kind .multi_return
	// - type of a variable
	// - type of a struct field.
	return_sym SymbolID = analyzer.void_sym_id
	// Child symbol is used to represent:
	//
	// - type parameter of array, map
	// - parameter of function
	// - field and method of struct
	// - field and method of interface
	// - variant of enum
	children []SymbolID
}

const kinds_in_multi_return_to_be_excluded = [SymbolKind.function, .variable, .field]

const type_defining_sym_kinds = [SymbolKind.struct_, .enum_, .typedef, .interface_, .sumtype]

const sym_kinds_allowed_to_print_parent = [SymbolKind.typedef, .function]

pub fn (sym Symbol) str() string {
	return sym.name
}

pub fn (sym Symbol) debug_str(loader SymbolInfoLoader, indent string) string {
	mut builder := strings.new_builder(30)

	builder.write_string('${indent}${sym.name}')
	if sym.is_type_defining_kind() {
		builder.write_string('{')
		children := sym.get_children(loader)
		for child in children {
			builder.write_string(child.debug_str(indent + '\t'))
			builder.write_byte(`\n`)
		}
		if children.len > 0 {
			builder.write_string('${indent}}')
		} else {
			builder.write_string(' }')
		}
	} else {
		match sym.kind {
			.variable, .field {
				builder.write_string(': ${sym.get_return(loader).name}')
			}
			.function {
				builder.write_string(': function -> ${sym.get_return(loader).name}')
			}
			else {
				builder.write_string('(${sym.kind})')
			}
		}
	}

	return builder.str()
}

pub fn (symbols []Symbol) str() string {
	return '[' + symbols.map(it.str()).join(', ') + ']'
}

// index locates the symbol with name `name` and returns its index. Returns `-1`
// if no such symbol were found.
pub fn (symbols []Symbol) index(name string) int {
	for i, v in symbols {
		if v.name == name {
			return i
		}
	}

	return -1
}

// index_by_row locates the symbol starts at row `row` and returns its index.
// Returns `-1` if no such symbol were found.
pub fn (symbols []Symbol) index_by_row(file_id int, row u32) int {
	for i, v in symbols {
		if v.file_id == file_id && v.range.start_point.row == row {
			return i
		}
	}

	return -1
}

// filter_by_file_id recursively finds all symbols and their children defined in
// given file.
pub fn (symbols []Symbol) filter_by_file_id(loader SymbolInfoLoader, file_id int) []Symbol {
	mut filtered := []Symbol{}
	for sym in symbols {
		if sym.file_id == file_id {
			filtered << sym
		}

		filtered_from_children := sym.get_children(loader)
			.filter(!symbols.exists(it.name))
			.filter(!filtered.exists(it.name))
			.filter_by_file_id(file_id)

		filtered << filtered_from_children
	}
	return filtered
}

// pub fn (mut infos []&Symbol) remove_symbol_by_range(file_path string, range C.TSRange) {
// 	mut to_delete_i := -1
// 	for i, v in infos {
// 		// not the best solution so far :(
// 		if v.file_path == file_path {
// 			eprintln('${v.name} ${v.range}')
// 		}
// 		if v.file_path == file_path && v.range.eq(range) {
// 			eprintln('deleted ${v.name}')
// 			to_delete_i = i
// 			break
// 		}
// 	}

// 	if to_delete_i == -1 {
// 		return
// 	}

// 	unsafe { infos[to_delete_i].free() }
// 	infos.delete(to_delete_i)
// }

// exists checks if there is a symbol named `name` in an array.
pub fn (symbols []Symbol) exists(name string) bool {
	return symbols.index(name) != -1
}

// get retreives the symbol named `name` in array, it no such symbol were found
// returns `none`.
pub fn (symbols []Symbol) get(name string) ?Symbol {
	index := symbols.index(name)
	return if index == -1 {
		none
	} else {
		symbols[index]
	}
}

// update_with updates symbol fields with given data.
pub fn (mut sym Symbol) update_with(other Symbol) {
	// skipped fields
	// sym.id = other.id
	// sym.is_top_level = other.is_top_level
	// sym.is_const = other.is_const
	sym.name = other.name
	sym.kind = other.kind
	sym.access = other.access
	sym.range = other.range
	sym.language = other.language
	sym.generic_placeholder_len = other.generic_placeholder_len
	sym.interface_children_len = other.interface_children_len
	sym.file_id = other.file_id
	sym.file_version = other.file_version
	sym.scope = other.scope
	sym.docstring = other.docstring.clone()
	sym.parent = other.parent
	sym.return_sym = other.return_sym
	sym.children = other.children.clone()
}

// update_local_symbol_with updates a local symbol with given data. Fields that
// are not used by a local symbol will not be updated compared to `update_with`.
pub fn (mut sym Symbol) update_local_symbol_with(other Symbol) {
	// skipped fields
	// sym.id
	// sym.is_top_level
	// sym.is_const
	// sym.kind = other.kind
	// sym.language = other.language
	// sym.generic_placeholder_len = other.generic_placeholder_len
	// sym.interface_children_len = other.interface_children_len
	// sym.scope = other.scope
	// sym.docstring = other.docstring.clone()
	// sym.parent = other.parent
	// sym.children = other.children.clone()
	sym.name = other.name
	sym.access = other.access
	sym.range = other.range
	sym.file_id = other.file_id
	sym.file_version = other.file_version
	sym.return_sym = other.return_sym
}

// get_parent returns copy of symbol's parent.
[inline]
pub fn (sym Symbol) get_parent(loader SymbolInfoLoader) Symbol {
	return loader.get_info(sym.parent)
}

// get_return returns copy of symbol's return symbol.
[inline]
pub fn (sym Symbol) get_return(loader SymbolInfoLoader) Symbol {
	return loader.get_info(sym.return_sym)
}

pub fn (sym Symbol) get_child(loader SymbolInfoLoader, index int) ?Symbol {
	id := sym.children[index] or { return none }
	return loader.get_info(id)
}

// get_children returns copy of symbol's children in an array.
[inline]
pub fn (sym Symbol) get_children(loader SymbolInfoLoader) []Symbol {
	return loader.get_infos(sym.children)
}

pub fn (sym Symbol) get_child_by_name(loader SymbolInfoLoader, name string) ?Symbol {
	names := loader.get_symbol_names(sym.children)
	index := names.index(name)
	if index == -1 {
		return none
	} else {
		id := sym.children[index]
		return loader.get_info(id)
	}
}

// add_child registers a symbol as child of given parent symbol, returns
// error when parent symbol already has a child with the same name.
pub fn (mut sym Symbol) add_child(new_child_sym Symbol) ! {
	// preventing duplicate field/variant in struct, enum, etc.
	if sym.children_syms.exists(new_child_sym.name) {
		return error('child exists. (name="${new_child_sym.name}")')
	}

	sym.children << new_child_sym.id
}

// add_child_allow_duplicated register a symbol as child of given symbol, even
// if parent symbol already has a child with the same name.
pub fn (mut sym Symbol) add_child_allow_duplicated(mut new_child_sym Symbol) ! {
	sym.children << new_child_sym.id
}

// is_void returns true if a symbol is void/invalid
pub fn (sym Symbol) is_void() bool {
	if sym.kind in [.ref, .array_] && sym.children_syms.len >= 1 {
		return sym.children_syms[0].is_void()
	}

	return sym.kind == .void
}

// is_returnable checks if symbol has return symbol for recording its type/return type.
pub fn (sym Symbol) is_returnable() bool {
	return sym.kind == .variable || sym.kind == .field || sym.kind == .function
}

// is_mutable checks if a symbol allows mutation access.
pub fn (sym Symbol) is_mutable() bool {
	return sym.access == .private_mutable || sym.access == .public_mutable || sym.access == .global
}

// is_type_defining_kind checks if a symbol defines a type (struct, enum, etc.).
pub fn (sym Symbol) is_type_defining_kind() bool {
	return sym.kind in analyzer.type_defining_sym_kinds
}

// is_reference checks if a symbol is a reference type.
// Currently this function only returns true for a `.ref` symbol. May also returns
// true for smart pointers in the future.
pub fn (sym Symbol) is_reference() bool {
	return sym.kind == .ref
}

// get_type_def_keyword returns a keyword corresponding to type definition used by
// kind of symbol.
pub fn (sym Symbol) get_type_def_keyword() ?string {
	return match sym.kind {
		.interface_ { 'interface' }
		.struct_ { 'struct' }
		.sumtype, .typedef { 'type' }
		else { none }
	}
}

[unsafe]
pub fn (sym &Symbol) free() {
	unsafe {
		for v in sym.children_syms {
			v.free()
		}
		sym.children_syms.free()
	}
}

// value_sym returns value type of array/map symbol.
fn (sym Symbol) value_sym() Symbol {
	if sym.kind == .array_ {
		return sym.children_syms[0] or { analyzer.void_sym }
	} else if sym.kind == .map_ {
		return sym.children_syms[1] or { analyzer.void_sym }
	} else {
		return analyzer.void_sym
	}
}

fn (sym &Symbol) count_ptr() int {
	mut ptr_count := 0
	mut starting_sym := unsafe { sym }
	// What is it doing?
	for !isnil(starting_sym) && starting_sym.kind == .ref {
		ptr_count++
	}
	return ptr_count
}

// final_sym returns the final symbol to be returned
// from container symbols (optional types, channel types, and etc.)
pub fn (sym &Symbol) final_sym() &Symbol {
	match sym.kind {
		.optional, .result {
			return sym.parent_sym
		}
		else {
			return sym
		}
	}
}

fn sort_syms_by_name(a &Symbol, b &Symbol) int {
	if a.name < b.name {
		return -1
	} else if a.name > b.name {
		return 1
	}

	return 0
}

fn sort_syms_by_access_and_name(a &Symbol, b &Symbol) int {
	if int(a.access) < int(b.access) {
		return -1
	} else if int(a.access) > int(b.access) {
		return 1
	}

	return sort_syms_by_name(a, b)
}

// get_fields returns a sorted field symbol array for type definition symbol
// (struct, enum, etc.).
pub fn (sym Symbol) get_fields(loader SymbolInfoLoader) ?[]Symbol {
	if !sym.is_type_defining_kind() {
		return none
	}

	mut syms := []Symbol{}

	for child in sym.get_children(loader) {
		if child.kind != .function {
			syms << child
		}
	}

	if syms.len == 0 {
		return none
	}

	syms.sort_with_compare(sort_syms_by_access_and_name)
	return syms
}

// get_methods returns a sorted method symbol array for type definition symbol
// (struct, enum, etc.).
pub fn (sym Symbol) get_methods(loader SymbolInfoLoader) ?[]Symbol {
	if !sym.is_type_defining_kind() {
		return none
	}

	mut syms := []Symbol{}

	for child in sym.get_children(loader) {
		if child.kind == .function {
			syms << child
		}
	}

	if syms.len == 0 {
		return none
	}

	syms.sort_with_compare(sort_syms_by_name)
	return syms
}

// deref returns internal symbol of a reference symbol, return none on a non-reference
// symbol
pub fn (sym Symbol) deref(loader SymbolInfoLoader) ?Symbol {
	if !sym.is_reference() {
		return none
	}

	return if sym.parent == analyzer.void_sym_id {
		none
	} else {
		sym.get_parent(loader)
	}
}

// deref_all deref a symbol until it's no longer a reference, returns extracted
// internal symbol. Returns none if a symbol is not a reference.
pub fn (sym Symbol) deref_all(loader SymbolInfoLoader) ?Symbol {
	if !sym.is_reference() {
		return none
	}

	mut target := sym.get_parent(loader)
	for target.id != analyzer.void_sym_id && target.kind == .ref {
		target = target.get_parent(loader)
	}

	return if target.id == void_sym_id {
		none
	} else {
		target
	}
}

// is_interface_satisfied checks if a symbol safisfies given interface.
pub fn is_interface_satisfied(loader SymbolInfoLoader, sym &Symbol, interface_sym &Symbol) bool {
	if sym.kind !in [.struct_, .typedef, .sumtype] {
		return false
	} else if interface_sym.kind != .interface_ {
		return false
	}

	children := sym.get_children(loader)
	interface_children = interface_sym.get_children(loader)
	for i in 0 .. interface_sym.interface_children_len {
		spec_sym := interface_children[i]
		selected_child_sym := children.get(spec_sym.name) or { return false }
		if spec_sym.kind == .field {
			if selected_child_sym.access != spec_sym.access
				|| selected_child_sym.kind != spec_sym.kind
				|| selected_child_sym.return_sym != spec_sym.return_sym {
				return false
			}
		} else if spec_sym.kind == .function {
			if selected_child_sym.kind != spec_sym.kind
				|| !compare_params_and_ret_type(selected_child_sym.children_syms, selected_child_sym.return_sym, spec_sym, false) {
				return false
			}
		}
	}
	return true
}

// pub fn (ars ArraySymbol) str() string {
// 	return
// }

// pub struct RefSymbol {
// pub mut:
// 	ref_count int = 1
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (rs RefSymbol) str() string {
// 	return '&'.repeat(rs.ref_count) + rs.parent_sym.str()
// }

// pub struct MapSymbol {
// pub mut:
// 	range C.TSRange
// 	key_parent ISymbol // string in map[string]Foo
// 	parent ISymbol // Foo in map[string]Foo
// }

// pub fn (ms MapSymbol) str() string {
// 	return 'map[${ms.key_parent}]${ms.parent}'
// }

// pub struct ChanSymbol {
// pub mut:
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (cs ChanSymbol) str() string {
// 	return 'chan ${cs.parent}'
// }

// pub struct OptionSymbol {
// pub mut:
// 	range C.TSRange
// 	parent ISymbol
// }

// pub fn (opts OptionSymbol) str() string {
// 	return '!${opts.parent}'
// }

pub struct BaseSymbolLocation {
pub:
	module_name string
	symbol_name string
	for_kind    SymbolKind
}

pub struct BindedSymbolLocation {
pub:
	for_sym_name string
	language     SymbolLanguage
	module_path  string
}

fn (locs []BindedSymbolLocation) get_path(sym_name string) !string {
	idx := locs.index(sym_name)
	if idx != -1 {
		return locs[idx].module_path
	}
	return error('not found!')
}

fn (locs []BindedSymbolLocation) index(sym_name string) int {
	for i, bsl in locs {
		if bsl.for_sym_name == sym_name {
			return i
		}
	}
	return -1
}
