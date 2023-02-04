module analyzer

import os

enum ResolveBranchType {
	@none
	if_expr
	match_expr
	or_block
}

// get_branch_pos_desc returns a string for describing position of branch.
fn (t ResolveBranchType) get_branch_pos_desc(index int) string{
	return match t {
		.@none { '' }
		.if_expr, .match_expr { 'on branch ${index}' }
		.or_block { 'in or block' }
	}
}

struct ResolutionInfo {
	// index of this symbol in multireturn, for single return expression, this
	// will always be 0.
	index int
	// index of branch in if, match, or block expression. Mainly used for error
	// reporting.
	branch int
	branch_type ResolveBranchType
mut:
	sym &Symbol
	has_err bool
	err_msg string
}

pub fn (mut r ResolutionInfo) error(msg string) {
	r.has_err = true
	r.err_msg = msg
}

fn (mut r ResolutionInfo) resolve_with(type_sym &Symbol) {
	mut sym := r.sym

	if !sym.return_sym.is_void() && type_sym != sym.return_sym {
		return_index_desc := 'at return value #${r.index + 1}'
		pos_desc := ' ' + r.branch_type.get_branch_pos_desc(r.branch)
		r.error('type mismatch: ${return_index_desc}${pos_desc}: got ${type_sym.name} (expected ${sym.return_sym.name})')
		return
	}

	match type_sym.kind {
		.multi_return {
			one_base_index := r.index + 1
			if one_base_index <= type_sym.children_syms.len {
				sym.return_sym = type_sym.children_syms[r.index]
			} else {
				r.error('number mismatch: tried to get value #${one_base_index}, only ${type_sym.children_syms.len} value(s) found.')
			}
		}
		else {
			sym.return_sym = type_sym
		}
	}
}

pub struct Resolver {
mut:
	// Each value in this map is an array of symbols that shares the same dependency.
	// Keies should be in form of `${mod_path}.${target_name}` to identify depended
	// symbol.
	resolve_center map[string][]ResolutionInfo
}

fn (r Resolver) get_symbol_identifier(mod_path string, name string) string {
	return '${mod_path}.${name}'
}

// register registers a symbol into resolve center wating for resolution.
// `file_path` is path to the file `sym` is in,
// `dependency_name` is name of depended symbol.
pub fn (mut r Resolver) register(mod_path string, dependency_name string, info ResolutionInfo) ! {
	ident := r.get_symbol_identifier(mod_path, dependency_name)
	mut channel := r.resolve_center[ident]

	if channel.any(it.sym == info.sym) {
		return error('sybmol already registered in channel')
	}

	channel << info
	r.resolve_center[ident] = channel
}

// resolve_with resolves all symbols in channel of `depended`
pub fn (mut r Resolver) resolve_with(depended &Symbol) {
	got_sym := if depended.is_returnable() {
		depended.return_sym
	} else {
		depended
	}
	if got_sym.is_void()
		|| got_sym.kind == .never {
		return
	}

	mod_path := os.dir(depended.file_path)
	ident := r.get_symbol_identifier(mod_path, depended.name)
	if ident !in r.resolve_center {
		return
	}

	for mut info in r.resolve_center[ident] {
		if info.has_err {
			continue
		}
		info.resolve_with(got_sym)
	}

	r.resolve_center[ident] = r.resolve_center[ident].filter(it.has_err)
}

// recover clears all error message in given channel.
pub fn (mut r Resolver) recover(file_path string, dependency_name string) {
	ident := r.get_symbol_identifier(file_path, dependency_name)
	if ident !in r.resolve_center {
		return
	}

	mut channel := r.resolve_center[ident]
	for mut info in channel {
		info.has_err = false
		info.err_msg = ''
	}
}

pub fn (r Resolver) report(mut reporter Reporter, file_path string) {
	for _, channel in r.resolve_center {
		for info in channel {
			if info.sym.file_path != file_path {
				continue
			}

			if info.has_err {
				reporter.report(
					message: info.err_msg
					range: info.sym.range
					file_path: info.sym.file_path
				)
			} else if info.sym.return_sym.is_void() {
				reporter.report(
					message: 'unresolved symbol ${info.sym.name}'
					range: info.sym.range
					file_path: info.sym.file_path
				)
			}
		}
	}
}
