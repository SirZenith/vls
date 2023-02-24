module analyzer

import os
import structures.depgraph
import tree_sitter
import ast

// used in symbol name of anonymous functions.
const anon_fn_prefix = '#anon_'

pub struct Store {
mut:
	anon_fn_counter int = 1
	// Array of full path of parsed file. Index of a file path in this array will
	// be used as ID of that file during the life time of a store object.
	file_paths []string
	symbol_mgr SymbolManager
	scope_mgr  ScopeManager
pub mut:
	// Default reporter to be used
	// Used for diagnostics
	reporter Reporter
	// Store unresolved symbols, update every time a new symbol is added to store.
	resolver &Resolver
	// Current version of the file
	cur_version int
	// List of imports per directory
	// map goes: map[<full dir path>][]Import
	imports ImportsMap
	// Hack-free way for auto-injected dependencies
	// to get referenced. This uses module name instead of
	// full path since the most common autoinjected modules
	// are on the vlib path.
	// map goes: map[<module name>]<aliased path>
	auto_imports map[string]string
	// Dependency tree. Used for tracking dependencies
	// as basis for removing symbols/scopes/imports
	// tree goes: tree[<full dir path>][]<full dir path>
	dependency_tree depgraph.Tree
	// Scope data for different opened files
	// map goes: map[<full file path>]<scope id>
	opened_scopes map[string]ScopeID
	// paths to be imported aside from the ones
	// specified from lookup paths specified from
	// import_modules_from_tree
	default_import_paths []string
	// Another hack-free way to get symbol information
	// from base symbols for specific container kinds.
	// (e.g. []string should not be looked up only inside
	// []string but also in builtin's array type as well)
	base_symbol_locations []BaseSymbolLocation
	// Locations to the registered binded symbols (a.k.a C.Foo or JS.document)
	binded_symbol_locations []BindedSymbolLocation
}

pub fn (mut ss Store) with(params AnalyzerContextParams) AnalyzerContext {
	file_id := ss.get_file_id_for_path(params.file_path)
	return new_context(AnalyzerContextParams{
		...params
		file_id: file_id
		store: unsafe { ss }
	})
}

pub fn (mut ss Store) default_context() AnalyzerContext {
	return ss.with(file_path: '')
}

// report inserts the report to the reporter
pub fn (mut ss Store) report(report Report) {
	ss.reporter.report(report)
}

[if trace ?]
pub fn (mut ss Store) report_resolve(file_path string) {
	file_id := ss.get_file_id_for_path_opt(file_path) or { return }
	ss.resolver.report(ss.symbol_mgr, mut ss.reporter, file_id, file_path)
}

[if trace ?]
pub fn (mut ss Store) trace_report(report Report) {
	ss.reporter.report(report)
}

// -----------------------------------------------------------------------------
// File paths management

// get_file_id_for_path returns file id in current store for given path. If that
// path is not already presented in store, it will be append to store's file list.
pub fn (mut ss Store) get_file_id_for_path(path string) int {
	mut index := ss.file_paths.index(path)
	if index < 0 {
		index = ss.file_paths.len
		ss.file_paths << path
	}

	return index
}

// get_file_id_for_path_opt returns file id in current store for given path. Return
// none when this path is not in store.
pub fn (ss Store) get_file_id_for_path_opt(path string) ?int {
	mut index := ss.file_paths.index(path)
	return if index < 0 {
		none
	} else {
		index
	}
}

// get_file_path_for_id returns file path corresponding to given id. `none` will
// be returned when no file path found.
pub fn (ss Store) get_file_path_for_id(id int) ?string {
	if id < 0 || id >= ss.file_paths.len {
		return none
	}

	return ss.file_paths[id]
}

// get_file_path_for_symbol returns path of file in which this symbol is defined.
// When no such file is found, `none` will be returned.
pub fn (ss Store) get_file_path_for_symbol(sym Symbol) ?string {
	return ss.get_file_path_for_id(sym.file_id)
}

// -----------------------------------------------------------------------------

// get_module_path returns module path corresponding to name `module_name` in
// given file. If nothing is found, return `none`.
pub fn (ss &Store) get_module_path_opt(file_path string, module_name string) ?string {
	file_name := os.base(file_path)
	file_dir := os.dir(file_path)
	import_lists := ss.imports[file_dir]
	for imp in import_lists {
		if imp.module_name == module_name {
			return imp.path
		}

		if file_name in imp.aliases && imp.aliases[file_name] == module_name {
			return imp.path
		}
	}

	return none
}

pub fn (ss &Store) get_module_path_from_sym(file_path string, symbol_name string) ?string {
	file_name := os.base(file_path)
	if import_lists := ss.imports[os.dir(file_path)] {
		for imp in import_lists {
			if file_name !in imp.symbols || symbol_name !in imp.symbols[file_name] {
				continue
			}

			return imp.path
		}
	}

	return none
}

// get_module_path returns module path corresponding to name `module_name` in
// given file. If module named `module_name` were not imported in given file,
// directory path of target file is returned instead.
pub fn (ss &Store) get_module_path(file_path string, module_name string) string {
	// empty names should return the current selected dir instead
	return ss.get_module_path_opt(file_path, module_name) or { os.dir(file_path) }
}

// find_symbol retrieves the symbol based on the given module name and symbol name
pub fn (ss &Store) find_symbol(file_path string, module_name string, name string) !Symbol {
	if name.len == 0 {
		return error('Name is empty.')
	}

	mut sym := void_sym

	module_path := ss.get_module_path(file_path, module_name)
	sym = ss.symbol_mgr.get_info_by_name(module_path, name)
	if !sym.is_void() {
		return sym
	}

	if aliased_path := ss.auto_imports[module_name] {
		sym = ss.symbol_mgr.get_info_by_name(aliased_path, name)
		if !sym.is_void() {
			return sym
		}
	}

	// Find C.Foo or JS.Foo
	if binded_module_path := ss.binded_symbol_locations.get_path(name) {
		sym = ss.symbol_mgr.get_info_by_name(binded_module_path, name)
		if !sym.is_void() {
			return sym
		}
	}

	// Find symbol if it selectively imported from module
	if mod_path := ss.get_module_path_from_sym(file_path, name) {
		sym = ss.symbol_mgr.get_info_by_name(mod_path, name)
		if !sym.is_void() {
			return sym
		}
	}

	return error('Symbol `${name}` not found.')
}

// find_fn_symbol finds the function symbol with the appropriate parameters and return type
pub fn (ss &Store) find_fn_symbol(file_path string, module_name string, return_sym &Symbol, params []&Symbol) ?Symbol {
	module_path := ss.get_module_path(file_path, module_name)
	symbols := ss.symbol_mgr.get_infos_by_module_path(module_path)
	for sym in symbols {
		parent_sym := sym.get_parent(ss.symbol_mgr)

		final_sym := if sym.kind == .typedef && parent_sym.kind == .function_type {
			parent_sym
		} else {
			sym
		}

		if final_sym.kind == .function_type && final_sym.name.starts_with(analyzer.anon_fn_prefix)
			&& sym.generic_placeholder_len == 0 {
			if !compare_params_and_ret_type(ss.symbol_mgr, params, return_sym, final_sym, true) {
				continue
			}

			// return the typedef'd function type or the anon fn type itself
			return sym
		}
	}
	return none
}

pub fn compare_params_and_ret_type(sym_loader SymbolInfoLoader, params []&Symbol, ret_type &Symbol, fn_to_compare &Symbol, include_param_name bool) bool {
	mut params_to_check := []int{cap: fn_to_compare.children.len}
	// defer {
	// 	unsafe { params_to_check.free() }
	// }

	// get a list of indices that are parameters
	children := fn_to_compare.get_children(sym_loader)
	for i, child in children {
		if child.kind != .variable {
			continue
		}
		params_to_check << i
	}
	if params.len != params_to_check.len {
		return false
	}
	mut params_left := params_to_check.len
	for i, param_idx in params_to_check {
		param_from_sym := children[param_idx]
		param_to_compare := params[i]
		if param_from_sym.return_sym == param_to_compare.return_sym {
			if include_param_name && param_from_sym.name != param_to_compare.name {
				break
			}
			params_left--
			continue
		}
		break
	}
	if params_left != 0 || ret_type.id != fn_to_compare.return_sym {
		return false
	}
	return true
}

pub const container_symbol_kinds = [SymbolKind.chan_, .array_, .map_, .ref, .variadic, .optional,
	.result, .multi_return]

// -----------------------------------------------------------------------------

// get_ident_for_symbol returns a string identifier for symbol.
pub fn (ss Store) get_ident_of_symbol(sym Symbol) ?string {
	return ss.symbol_mgr.get_ident(ss, sym)
}

pub fn (ss Store) get_ident_of_symbol_id(id SymbolID) ?string {
	return ss.symbol_mgr.get_ident_of_id(ss, id)
}

// get_symbols_by_file_path retrieves all symbols defined in given file.
pub fn (ss Store) get_symbols_by_file_path(file_path string) []SymbolID {
	file_id := ss.get_file_id_for_path_opt(file_path) or { return [] }
	dir := os.dir(file_path)

	return ss.symbol_mgr.get_symbols_by_file_id(dir, file_id)
}

// has_file_path checks if the data of a specific file_path already exists
pub fn (ss &Store) has_file_path(file_path string) bool {
	file_id := ss.get_file_id_for_path_opt(file_path) or { return false }
	dir := os.dir(file_path)

	return ss.symbol_mgr.has_file_id(dir, file_id)
}

// delete removes the given path of a workspace/project if possible.
// The directory is only deleted if there are no projects dependent on it.
// It also removes the dependencies with the same condition
pub fn (mut ss Store) delete(dir string, excluded_dir ...string) {
	// do not delete data if dir is an auto import!
	for _, path in ss.auto_imports {
		if path == dir {
			// return immediately if found
			return
		}
	}

	is_used := ss.dependency_tree.has_dependents(dir, ...excluded_dir)
	if is_used {
		return
	}

	if dep_node := ss.dependency_tree.get_node(dir) {
		// get all dependencies
		all_dependencies := dep_node.get_all_dependencies()

		// delete all dependencies if possible
		for dep in all_dependencies {
			ss.delete(dep, dir)
		}

		// delete dir in dependency tree
		ss.dependency_tree.delete(dir)
	}

	// delete all imports from unused dir
	if !is_used {
		ss.symbol_mgr.delete_module(dir)
		for i := 0; ss.imports[dir].len != 0; {
			ss.imports[dir].delete(i)
		}
	}
}

// register_symbol registers or updates a symbol with given info, and returns
// ID of changed symbol.
pub fn (mut ss Store) register_symbol(info Symbol) !SymbolID {
	return ss.symbol_mgr.register_symbol(mut ss, info)!
}

// -----------------------------------------------------------------------------

// get_scope_from_node is a wrapper around ScopeManager.get_scope_from_node.
pub fn (mut ss Store) get_scope_from_node(file_path string, node ast.Node) !ScopeID {
	return ss.scope_mgr.get_scope_from_node(file_path, node)
}

// symbol_name_from_node extracts the symbol's kind, name, and module name from the given node
pub fn symbol_name_from_node(node ast.Node, src_text tree_sitter.SourceText) (SymbolKind, string, string) {
	mut module_name := ''
	mut symbol_name := ''

	match node.type_name {
		.qualified_type {
			if module_node := node.child_by_field_name('module') {
				module_name = module_node.text(src_text)
			}

			if name_node := node.child_by_field_name('name') {
				symbol_name = name_node.text(src_text)
			}

			return SymbolKind.placeholder, module_name, symbol_name
		}
		.pointer_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.ref, module_name, '&' + symbol_name
		}
		.array_type, .fixed_array_type {
			mut limit := ''
			if limit_field := node.child_by_field_name('limit') {
				limit = limit_field.text(src_text)
			}

			if el_node := node.child_by_field_name('element') {
				_, module_name, symbol_name = symbol_name_from_node(el_node, src_text)
			}
			return SymbolKind.array_, module_name, '[${limit}]' + symbol_name
		}
		.map_type {
			mut key_module_name := ''
			mut key_symbol_name := ''
			mut val_module_name := ''
			mut val_symbol_name := ''
			mut key_symbol_text := ''
			mut value_symbol_text := ''
			if key_node := node.child_by_field_name('key') {
				key_symbol_text = key_node.text(src_text)
				_, key_module_name, key_symbol_name = symbol_name_from_node(key_node,
					src_text)
			}

			if value_node := node.child_by_field_name('value') {
				value_symbol_text = value_node.text(src_text)
				_, val_module_name, val_symbol_name = symbol_name_from_node(value_node,
					src_text)
			}

			if (key_module_name.len != 0 && val_module_name.len == 0)
				|| (key_module_name == val_module_name) {
				// if key type uses a custom type, return the symbol in the key's origin module
				return SymbolKind.map_, key_module_name, 'map[${key_symbol_name}]${value_symbol_text}'
			} else if key_module_name.len == 0 && val_module_name.len != 0 {
				// if key is builtin type and key type is not, use the module from the value type
				return SymbolKind.map_, val_module_name, 'map[${key_symbol_text}]${val_symbol_name}'
			} else {
				module_name = ''
			}

			return SymbolKind.map_, '', node.text(src_text)
		}
		.generic_type {
			if child_type_node := node.named_child(0) {
				return symbol_name_from_node(child_type_node, src_text)
			}
		}
		.channel_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.chan_, module_name, 'chan ' + symbol_name
		}
		.option_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			if symbol_name == 'void' {
				symbol_name = ''
			}
			return SymbolKind.optional, module_name, '?' + symbol_name
		}
		.result_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			if symbol_name == 'void' {
				symbol_name = ''
			}
			return SymbolKind.result, module_name, '!' + symbol_name
		}
		.function_type, .fn_literal {
			return SymbolKind.function_type, module_name, symbol_name
		}
		.variadic_type {
			if child_type_node := node.named_child(0) {
				_, module_name, symbol_name = symbol_name_from_node(child_type_node, src_text)
			}
			return SymbolKind.variadic, module_name, '...' + symbol_name
		}
		.multi_return_type {
			return SymbolKind.multi_return, '', node.text(src_text)
		}
		.call_expression {
			function_node := node.child_by_field_name('function') or {
				return SymbolKind.typedef, '', 'void'
			}
			return symbol_name_from_node(function_node, src_text)
		}
		else {
			// type_identifier should go here
			return SymbolKind.placeholder, module_name, node.text(src_text)
		}
	}

	return SymbolKind.typedef, '', 'void'
}

// find_fn_symbol_by_type_node tries to find anonymous function signature symbol
// used in `node`.
fn (mut store Store) find_fn_symbol_by_type_node(file_path string, sym_kind SymbolKind, module_name string, node ast.Node, src_text tree_sitter.SourceText) Symbol {
	// anonymous function
	mut parameters := []&Symbol{}
	if param_node := node.child_by_field_name('parameters') {
		file_id := store.get_file_id_for_path(file_path)
		mut ctx := new_context(
			store: store
			file_id: file_id
			file_path: file_path
			text: src_text
		)
		parameters << extract_parameter_list(mut ctx, param_node)
	}

	return_sym := if result_node := node.child_by_field_name('result') {
		store.find_symbol_by_type_node(file_path, result_node, src_text) or { void_sym }
	} else {
		void_sym
	}

	if result := store.find_fn_symbol(file_path, module_name, return_sym, parameters) {
		return result
	}

	file_id := store.get_file_id_for_path(file_path)
	// TODO: register new symbol
	mut new_sym := Symbol{
		name: analyzer.anon_fn_prefix + store.anon_fn_counter.str()
		file_id: file_id
		file_version: store.cur_version
		is_top_level: true
		kind: sym_kind
		return_sym: return_sym.id
	}

	for mut param in parameters {
		// TODO: try register all children to symbol_mgr, in case there's new type
		// identtifier used in parameter list.
		new_sym.add_child(param) or { continue }
	}

	store.anon_fn_counter++
	return new_sym
}

// find_symbol_by_type_node returns the symbol used/defined by given node.
// Basically `node` is a type identifier. If no existing symbol were found, a
// new symbol will be registered to store for this node.
pub fn (mut store Store) find_symbol_by_type_node(file_path string, node ast.Node, src_text tree_sitter.SourceText) !Symbol {
	if node.is_null() || src_text.len() == 0 {
		return error('null node or empty source text')
	}

	sym_kind, module_name, symbol_name := symbol_name_from_node(node, src_text)

	// try to find existing symbol.
	if sym_kind == .function_type {
		return store.find_fn_symbol_by_type_node(file_path, sym_kind, module_name, node, src_text)
	}

	if result := store.find_symbol(file_path, module_name, symbol_name) {
		return result
	}

	// prepare to register new symbol to store.
	module_path := store.get_module_path(file_path, module_name)
	placehoder_file_path := os.join_path(module_path, 'placeholder.vv')
	file_id := store.get_file_id_for_path(placehoder_file_path)

	mut new_sym := Symbol{
		name: symbol_name
		is_top_level: true
		file_id: file_id
		file_version: 0
		kind: sym_kind
	}

	// TODO: is it better for this function to return SymbolID instead of Symbol.
	match sym_kind {
		.array_ {
			value_type_node := node.child_by_field_name('element') or {
				return error('no value type identifier found in array node')
			}
			value_type_sym := store.find_symbol_by_type_node(file_path, value_type_node,
				src_text)!
			new_sym.add_child(value_type_sym) or {}
		}
		.map_ {
			key_node := node.child_by_field_name('key') or {
				return error('no key type identifier found in map node')
			}
			key_sym := store.find_symbol_by_type_node(file_path, key_node, src_text)!
			new_sym.add_child_allow_duplicated(key_sym)

			value_node := node.child_by_field_name('value') or {
				return error('no value type identifier found in map node')
			}
			val_sym := store.find_symbol_by_type_node(file_path, value_node, src_text)!
			new_sym.add_child_allow_duplicated(val_sym)
		}
		.chan_, .ref, .optional, .result {
			if symbol_name !in ['?', '!'] {
				child_type_node := node.named_child(0) or {
					return error('inner type node not found in option/result type')
				}
				mut ref_sym := store.find_symbol_by_type_node(file_path, child_type_node,
					src_text)!
				if ref_sym.name.len != 0 {
					new_sym.parent = ref_sym.id
				} else {
					// TODO:
					return error('empty ref sym')
				}
			}
		}
		.multi_return, .variadic {
			types_len := node.named_child_count()
			for i in 0 .. types_len {
				type_node := node.named_child(i) or { continue }
				mut type_sym := store.find_symbol_by_type_node(file_path, type_node, src_text) or {
					continue
				}
				if !type_sym.is_void() {
					new_sym.add_child_allow_duplicated(type_sym)
				}
			}
		}
		else {}
	}

	new_id := store.register_symbol(new_sym)!

	return store.symbol_mgr.get_info(new_id)
}

// infer_symbol_from_node returns the specified symbol based on the given node.
// This is different from infer_value_type_from_node as this returns the symbol
// instead of symbol's return type or parent for example
pub fn (mut ss Store) infer_symbol_from_node(file_path string, node ast.Node, src_text tree_sitter.SourceText) !Symbol {
	if node.is_null() {
		return error('null node')
	}

	mut module_name := ''
	mut type_name := ''

	match node.type_name {
		.interpreted_string_literal {
			type_name = 'string'
		}
		.identifier, .binded_identifier {
			// Identifier symbol finding strategy
			// Find first in symbols
			// find the symbol in scopes
			// return void if none
			ident_text := node.text(src_text)
			if id := ss.scope_mgr.get_file_scope_id(file_path) {
				if sym := ss.scope_mgr.get_symbol_with_range(ss.symbol_mgr, id, ident_text,
					node.range())
				{
					return sym
				}
			}

			return ss.find_symbol(file_path, module_name, ident_text)!
		}
		.mutable_identifier, .mutable_expression {
			first_child := node.named_child(0) or {
				return error('failed to get identifier node from mutable expressioin')
			}
			return ss.infer_symbol_from_node(file_path, first_child, src_text)
		}
		.field_identifier {
			mut parent := node.parent() or { return error('no field parent found') }
			for parent.type_name in [.keyed_element, .literal_value] {
				parent = parent.parent() or { return error('no parent found') }
			}

			parent_sym := ss.infer_symbol_from_node(file_path, parent, src_text) or { void_sym }
			ident_text := node.text(src_text)
			if !parent_sym.is_void() {
				if parent.type_name == .struct_field_declaration {
					return parent_sym
				} else if child_sym := parent_sym.get_child_by_name(ss.symbol_mgr, ident_text) {
					return child_sym
				}
			}

			return ss.find_symbol(file_path, module_name, ident_text) or {
				id := ss.scope_mgr.get_file_scope_id(file_path) or {
					return error('file ${file_path} is never opened.')
				}
				ss.scope_mgr.get_symbol_with_range(ss.symbol_mgr, id, ident_text, node.range()) or {
					return error('symbol not found')
				}
			}
		}
		.type_selector_expression {
			// TODO: assignment_declaration
			// if parent.type_name() != 'literal_value' {
			// 	parent = parent.parent()
			// }
			field_node := node.child_by_field_name('field_name') or {
				return error('no field node found')
			}
			if type_node := node.child_by_field_name('type') {
				parent_sym := ss.infer_symbol_from_node(file_path, type_node, src_text)!
				field_name := field_node.text(src_text)
				child_sym := parent_sym.get_child_by_name(ss.symbol_mgr, field_name) or {
					return error('symbol not found')
				}
				return child_sym
			} else {
				// for shorhand enum
				enum_value := field_node.text(src_text)
				module_path := os.dir(file_path)
				symbols := ss.symbol_mgr.get_infos_by_module_path(module_path)
				for sym in symbols {
					if sym.kind != .enum_ {
						continue
					}
					enum_member := sym.get_child_by_name(ss.symbol_mgr, enum_value) or { continue }
					return enum_member
				}
			}
		}
		.type_initializer {
			type_node := node.child_by_field_name('type') or {
				return error('no type identifier found in type initializer')
			}
			return ss.find_symbol_by_type_node(file_path, type_node, src_text) or {
				error('not found')
			}
		}
		.type_identifier, .array, .array_type, .map_type, .pointer_type, .variadic_type,
		.builtin_type, .channel_type, .fn_literal {
			return ss.find_symbol_by_type_node(file_path, node, src_text) or {
				return error('not found')
			}
		}
		.const_spec {
			name_node := node.child_by_field_name('name') or { return error('no name node found') }
			return ss.find_symbol_by_type_node(file_path, name_node, src_text) or {
				error('not found')
			}
		}
		.selector_expression {
			operand := node.child_by_field_name('operand') or {
				return error('no operand node found')
			}

			mut root_sym := ss.infer_symbol_from_node(file_path, operand, src_text) or { void_sym }
			if root_sym.is_void() {
				// no ordinary symbol found, treat operand as a module name.
				if operand.type_name != .identifier {
					return error('non-identifer operand in selector expression')
				}

				module_name = operand.text(src_text)
				field_node := node.child_by_field_name('field') or {
					return error('no field node found')
				}
				type_name = field_node.text(src_text)
			} else {
				if root_sym.is_returnable() {
					root_sym = root_sym.get_return(ss.symbol_mgr)
				}
				field_node := node.child_by_field_name('field') or {
					return error('no field node found')
				}
				child_name := field_node.text(src_text)
				if sym := root_sym.get_child_by_name(ss.symbol_mgr, child_name) {
					return sym
				}

				for root_sym.is_reference() {
					root_sym = root_sym.deref(ss.symbol_mgr) or { break }
					if sym := root_sym.get_child_by_name(ss.symbol_mgr, child_name) {
						return sym
					}
				}

				mut found := false
				for base_sym_loc in ss.base_symbol_locations {
					if base_sym_loc.for_kind != root_sym.kind {
						continue
					}
					root_sym = ss.find_symbol(file_path, base_sym_loc.module_name,
							base_sym_loc.symbol_name) or { continue }

					found = true
					break
				}

				return if !found {
					error('not found')
				} else if sym := root_sym.get_child_by_name(ss.symbol_mgr, child_name) {
					sym
				} else {
					error('not found')
				}
			}
		}
		.keyed_element {
			mut parent := node.parent() or {
				return error('failed to get parent of key value pair')
			}
			if parent.type_name in [.literal_value, .map_] {
				parent = parent.parent() or {
					return error('failed to get parent of literal body')
				}
			}
			mut selected_node := node.child_by_field_name('name') or {
				return error('no name node found')
			}
			if !selected_node.type_name.is_identifier() {
				// this is a key-value pair in map
				selected_node = node.child_by_field_name('value') or {
					return error('no value node found')
				}
			}
			if parent.type_name in [.literal_value, .type_initializer] {
				mut parent_sym := ss.infer_symbol_from_node(file_path, parent, src_text)!
				if inner := parent_sym.deref(ss.symbol_mgr) {
					parent_sym = inner
				}
				selected_name := selected_node.text(src_text)

				return if sym := parent_sym.get_child_by_name(ss.symbol_mgr, selected_name) {
					sym
				} else if parent_sym.name == 'map' || parent_sym.name == 'array' {
					ss.infer_symbol_from_node(file_path, selected_node, src_text)!
				} else {
					error('not found')
				}
			} else {
				return ss.infer_symbol_from_node(file_path, selected_node, src_text)
			}
		}
		.call_expression {
			function_node := node.child_by_field_name('function') or {
				return error('no function node found in call expression')
			}
			return ss.infer_symbol_from_node(file_path, function_node, src_text)
		}
		.parameter_declaration {
			mut parent := node.parent() or {
				return error('no parent node found for parameter declaration')
			}
			for parent.type_name !in [.function_declaration, .interface_spec] {
				parent = parent.parent() or { return error('failed to get parent') }
				if parent.is_null() {
					return error('null parent node')
				}
			}

			if parent.type_name == .function_declaration {
				parent = parent.child_by_field_name('name') or {
					return error('no name node found')
				}
			}

			parent_sym := ss.infer_symbol_from_node(file_path, parent, src_text)!
			name_node := node.child_by_field_name('name') or { return error('no name node found') }
			child_name := name_node.text(src_text)
			return parent_sym.get_child_by_name(ss.symbol_mgr, child_name) or {
				error('not found')
			}
		}
		.struct_field_declaration, .interface_spec {
			mut parent := node.parent() or { return error('failed to get parent') }
			for parent.type_name !in [.struct_declaration, .interface_declaration] {
				parent = parent.parent() or { return error('failed to get parent') }
			}

			// eprintln(parent.type_name())
			parent_name_node := parent.child_by_field_name('name') or {
				return error('no name node found')
			}
			parent_sym := ss.infer_symbol_from_node(file_path, parent_name_node, src_text)!
			child_name_node := node.child_by_field_name('name') or {
				return error('no name node found')
			}
			return parent_sym.get_child_by_name(ss.symbol_mgr, child_name_node.text(src_text)) or {
				error('no symbol found')
			}
		}
		.function_declaration {
			name_node := node.child_by_field_name('name') or { return error('no name node found') }
			receiver_node := node.child_by_field_name('receiver') or {
				return ss.infer_symbol_from_node(file_path, name_node, src_text)
			}

			receiver_param_count := receiver_node.named_child_count()
			if receiver_param_count != 0 {
				receiver_param_node := receiver_node.named_child(0) or {
					return error('failed to get receiver parameter node')
				}
				type_node := receiver_param_node.child_by_field_name('type') or {
					return error('no type identifier found for receiver')
				}
				parent_sym := ss.infer_symbol_from_node(file_path, type_node, src_text)!
				return parent_sym.get_child_by_name(ss.symbol_mgr, name_node.text(src_text)) or {
					error('not found')
				}
			} else {
				return ss.infer_symbol_from_node(file_path, name_node, src_text)
			}
		}
		else {
			// eprintln(node_type)
			// eprintln(node.parent().type_name())
			// return analyzer.void_sym
		}
	}

	return ss.find_symbol(file_path, module_name, type_name)
}

// infer_value_type_from_node returns the symbol based on the given node
pub fn (mut ss Store) infer_value_type_from_node(file_path string, node ast.Node, src_text tree_sitter.SourceText) Symbol {
	if node.is_null() {
		return void_sym
	}

	mut type_name := ''

	match node.type_name {
		.none_ {
			// TODO: None is already registered in builtin.v but
			// haven't done interface checking yet
			// type_name = 'none'
			type_name = 'IError'
		}
		.true_, .false_ {
			type_name = 'bool'
		}
		.int_literal {
			type_name = 'int'
		}
		.float_literal {
			type_name = 'f32'
		}
		.rune_literal {
			type_name = 'u8'
		}
		.interpreted_string_literal {
			type_name = 'string'
		}
		.range {
			// TODO: detect starting and ending types
			type_name = '[]int'
		}
		.array {
			child_type_node := node.named_child(0) or { return void_sym }

			inferred_value_sym := ss.infer_value_type_from_node(file_path, child_type_node,
				src_text)
			type_name = '[]' + inferred_value_sym.name
			if sym := ss.find_symbol(file_path, '', type_name) {
				return sym
			}

			placehoder_file_path := os.join_path(ss.get_module_path(file_path,
				''), 'placeholder.vv')
			file_id := ss.get_file_id_for_path(placehoder_file_path)

			new_id := ss.register_symbol(
				name: type_name
				is_top_level: true
				file_id: file_id
				file_version: 0
				kind: .array_
				children: [inferred_value_sym.id]
			) or { return void_sym }

			return ss.symbol_mgr.get_info(new_id)
		}
		.binary_expression {
			// TODO:
			left_node := node.child_by_field_name('left') or { return void_sym }
			// op_node := node.child_by_field_name('operator')
			// right_node := node.child_by_field_name('right')
			mut left_sym := ss.infer_value_type_from_node(file_path, left_node, src_text)
			if left_sym.is_returnable() {
				left_sym = left_sym.get_return(ss.symbol_mgr)
			}
			// right_sym := ss.infer_value_type_from_node(right_node.text(src_text))
			return left_sym
		}
		.unary_expression {
			operator_node := node.child_by_field_name('operator') or { return void_sym }
			operand_node := node.child_by_field_name('operand') or { return void_sym }
			mut op_sym := ss.infer_value_type_from_node(file_path, operand_node, src_text)
			if op_sym.is_returnable() {
				op_sym = op_sym.get_return(ss.symbol_mgr)
			}

			operator_type_name := operator_node.raw_node.type_name()
			if operator_type_name in ['+', '-', '~', '^', '*'] && op_sym.name !in numeric_types {
				return void_sym
			} else if operator_type_name == '!' && op_sym.name != 'bool' {
				return void_sym
			} else if operator_type_name == '*' && op_sym.kind != .ref {
				return void_sym
			} else if operator_type_name == '&' && op_sym.count_ptr(ss.symbol_mgr) > 2 {
				return void_sym
			} else if operator_type_name == '<-' && op_sym.kind != .chan_ {
				return void_sym
			} else {
				return op_sym
			}
		}
		.identifier {
			got_sym := ss.infer_symbol_from_node(file_path, node, src_text) or { void_sym }
			if got_sym.is_returnable() {
				return got_sym.get_return(ss.symbol_mgr)
			}
			return got_sym
		}
		.call_expression {
			got_sym := ss.infer_symbol_from_node(file_path, node, src_text) or {
				return void_sym
			}
			if got_sym.is_returnable() {
				node_count := node.named_child_count()
				return_sym := got_sym.get_return(ss.symbol_mgr)

				if last_node := node.named_child(node_count - 1) {
					if return_sym.kind in [.optional, .result]
						&& last_node.type_name == .option_propagator {
						return return_sym.final_sym(ss.symbol_mgr)
					}
				}
				return return_sym
			}
			return got_sym
		}
		.type_selector_expression, .type_cast_expression {
			if type_node := node.child_by_field_name('type') {
				if parent_sym := ss.infer_symbol_from_node(file_path, type_node, src_text) {
					return parent_sym
				}
			}
			return void_sym
		}
		// 'argument_list' {
		// 	return ss.infer_value_type_from_node(node.parent(), src_text)
		// }
		.unsafe_expression {
			if block_node := node.named_child(0) {
				block_child_len := node.named_child_count()
				if block_child_len != u32(1) {
					return void_sym
				}

				if first_node := block_node.named_child(0) {
					return ss.infer_value_type_from_node(file_path, first_node, src_text)
				}
			}

			return void_sym
		}
		.slice_expression {
			// TODO: transfer this to semantic analyzer
			if operand_node := node.child_by_field_name('operand') {
				operand_sym := ss.infer_value_type_from_node(file_path, operand_node,
					src_text)
				if operand_sym.is_void()
					|| (operand_sym.name != 'string' && operand_sym.kind != .array_) {
					return void_sym
				}

				if start_node := node.child_by_field_name('start') {
					start_sym := ss.infer_value_type_from_node(file_path, start_node,
						src_text)
					if start_sym.name != 'int' {
						return void_sym
					}

					if end_node := node.child_by_field_name('end') {
						end_sym := ss.infer_value_type_from_node(file_path, end_node,
							src_text)
						if end_sym.name != 'int' {
							return void_sym
						}

						return operand_sym
					}
				}
			}

			return void_sym
		}
		.index_expression {
			// TODO: transfer this to semantic analyzer
			if operand_node := node.child_by_field_name('operand') {
				operand_sym := ss.infer_value_type_from_node(file_path, operand_node,
					src_text)
				if operand_sym.is_void() {
					return void_sym
				}

				if index_node := node.child_by_field_name('index') {
					index_sym := ss.infer_value_type_from_node(file_path, index_node,
						src_text)
					if index_sym.name != 'int' {
						return void_sym
					}

					return operand_sym.get_child(ss.symbol_mgr, 0) or { void_sym }
				}
			}

			return void_sym
		}
		else {
			return ss.infer_symbol_from_node(file_path, node, src_text) or { void_sym }
		}
	}

	return ss.find_symbol(file_path, '', type_name) or {
		// ss.report_error(report_error('Invalid type $type_name', node.range()))
		void_sym
	}
}

// delete_symbol_at_node removes a specific symbol from a specific portion of the node
pub fn (mut ss Store) delete_symbol_at_node(file_path string, root_node ast.Node, src tree_sitter.SourceText, start_line u32, end_line u32) bool {
	// remove by scope
	if scope_id := ss.scope_mgr.get_file_scope_id(file_path) {
		ss.scope_mgr.remove_symbols_by_line(ss.symbol_mgr, scope_id, start_line, end_line)
	}

	// remove by node
	mut cursor := new_tree_cursor(root_node, start_line_nr: start_line)

	dir := os.dir(file_path)
	file_id := ss.get_file_id_for_path(file_path)

	for node in cursor {
		if !within_range(node.range(), start_line, end_line) {
			break
		}

		match node.type_name {
			.const_spec, .global_var_spec, .global_var_declaration, .function_declaration,
			.interface_declaration, .enum_declaration, .type_declaration, .struct_declaration {
				name_node := node.child_by_field_name('name') or { continue }
				symbols := ss.symbol_mgr.get_infos_by_module_path(dir)
				idx := symbols.index_by_row(file_id, node.start_point().row)
				if idx != -1 && idx < ss.symbols[dir].len {
					language := symbols[idx].language
					if language != .v {
						symbol_name := name_node.text(src)
						binded_location_idx := ss.binded_symbol_locations.index(symbol_name)
						if binded_location_idx != -1
							&& ss.binded_symbol_locations[binded_location_idx].module_path == dir {
							ss.binded_symbol_locations.delete(binded_location_idx)
						}
					}
					if node.type_name == .function_declaration {
						scope_id := symbols[idx].scope
						ss.scope_mgr.remove_symbols_by_line(ss.symbol_mgr, scope_id, start_line, end_line)
					}
					ss.symbol_mgr.delete_symbol_from_module(dir, idx)
				} else if node.type_name == .function_declaration {
					// for methods
					fn_sym := ss.infer_symbol_from_node(file_path, node, src) or { void_sym }
					mut fn_parent_sym := fn_sym.get_parent(ss.symbol_mgr)

					// delete the method if and only if method is not void (nor null)
					if !fn_sym.is_void() && !fn_parent_sym.is_void() {
						child_idx := parent_sym.get_children(ss.symbol_mgr).index_by_row(file_id, node.start_point().row)
						if child_idx != -1 {
							fn_parent_sym.children.delete(child_idx)
						}
					}

					ss.symbol_mgr.update_symbol(fn_parent_sym.id, fn_parent_sym) or {}
				}
			}
			.import_declaration {
				mut imp_module := ss.imports.find_by_position(file_path, node.range()) or {
					continue
				}
				// if the current import node is not the same as before,
				// untrack and remove the import entry asap
				imp_module.untrack_file(file_path)

				// let cleanup_imports do the job
			}
			else {}
		}
	}

	return false
}

// register_auto_import registers the import as an auto-import. This
// is used for most important imports such as "builtin"
pub fn (mut ss Store) register_auto_import(imp Import, to_alias string) {
	ss.auto_imports[to_alias] = imp.path
}

pub fn (ss &Store) is_module(file_path string, module_name string) bool {
	_ = ss.get_module_path_opt(file_path, module_name) or { return false }
	return true
}

pub fn (ss &Store) is_imported(importer_file_path string, path string) bool {
	if import_lists := ss.imports[os.dir(importer_file_path)] {
		for imp in import_lists {
			if imp.path != path {
				continue
			}

			if importer_file_path in imp.ranges {
				return true
			}
		}
	}

	for _, imp_path in ss.auto_imports {
		if imp_path == path {
			return true
		}
	}

	return false
}
