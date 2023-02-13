module analyzer

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
	sym_id SymbolID
	has_err bool
	err_msg string
}

pub fn (mut r ResolutionInfo) error(msg string) {
	r.has_err = true
	r.err_msg = msg
}

pub fn (mut r ResolutionInfo) recover() {
	r.has_err = false
	r.err_msg = ''
}

fn (mut r ResolutionInfo) resolve_with(mut mgr SymbolManager, id SymbolID) {
	mut sym := mgr.get_info(r.sym_id)

	if sym.return_sym != analyzer.void_sym_id && id != sym.return_sym {
		return_index_desc := 'at return value #${r.index + 1}'
		pos_desc := ' ' + r.branch_type.get_branch_pos_desc(r.branch)
		return_sym_name := mgr.get_symbol_name(sym.return_sym)
		type_sym_name := mgr.get_symbol_name(id)

		r.error('type mismatch: ${return_index_desc}${pos_desc}: got ${type_sym_name} (expected ${return_sym_name})')
		return
	}

	type_sym := mgr.get_info(id)
	match type_sym.kind {
		.multi_return {
			one_base_index := r.index + 1
			if one_base_index <= type_sym.children.len {
				sym.return_sym = type_sym.children[r.index]
			} else {
				r.error('number mismatch: tried to get value #${one_base_index}, only ${type_sym.children.len} value(s) found.')
			}
		}
		else {
			sym.return_sym = id
		}
	}

	mgr.update_symbol(r.sym_id, sym) or {
		r.error(err.msg())
	}
}

pub struct Resolver {
mut:
	// Each value in this map is an array of symbols that shares the same dependency.
	// Keies should be in form of `${mod_path}.${target_name}` to identify depended
	// symbol.
	resolve_center map[string][]ResolutionInfo
}

// register registers a symbol into resolve center wating for resolution.
// `file_path` is path to the file `sym` is in,
// `dependency_name` is name of depended symbol.
pub fn (mut r Resolver) register(ident string, info ResolutionInfo) ! {
	mut channel := r.resolve_center[ident]

	if channel.any(it.sym_id == info.sym_id) {
		return error('sybmol already registered in channel')
	}

	channel << info
	r.resolve_center[ident] = channel
}

// resolve_with resolves all symbols in channel of `depended`
pub fn (mut r Resolver) resolve_with(mut mgr SymbolManager, ident string, depended Symbol) {
	if ident !in r.resolve_center {
		return
	}

	got_sym := if depended.is_returnable() {
		mgr.get_info(depended.return_sym)
	} else {
		depended
	}
	if got_sym.is_void() || got_sym.kind == .never {
		return
	}

	for mut info in r.resolve_center[ident] {
		if info.has_err {
			continue
		}
		info.resolve_with(mut mgr, got_sym.id)
	}

	r.resolve_center[ident] = r.resolve_center[ident].filter(it.has_err)
}

// recover clears all error message in given channel.
pub fn (mut r Resolver) recover(ident string) {
	if ident !in r.resolve_center {
		return
	}

	mut channel := r.resolve_center[ident]
	for mut info in channel {
		info.recover()
	}
}

pub fn (r Resolver) report(loader SymbolInfoLoader, mut reporter Reporter, file_id int, report_file_path string) {
	for _, channel in r.resolve_center {
		for info in channel {
			sym := loader.get_info(info.sym_id)
			if sym.file_id != file_id {
				continue
			}

			if info.has_err {
				reporter.report(
					message: info.err_msg
					range: sym.range
					file_path: report_file_path
				)
			} else if sym.return_sym == analyzer.void_sym_id {
				reporter.report(
					message: 'unresolved symbol ${sym.name}'
					range: sym.range
					file_path: report_file_path
				)
			}
		}
	}
}
