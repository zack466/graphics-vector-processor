import struct
from dataclasses import dataclass
from typing import List, Dict, Tuple, Optional, Union, Any
from lark import Lark, Transformer, v_args

# ==========================================
# 1. AST Node Definitions
# ==========================================

class ASTNode:
    pass

@dataclass
class Program(ASTNode):
    statements: List[ASTNode]

@dataclass
class Block(ASTNode):
    statements: List[ASTNode]

@dataclass
class FuncDecl(ASTNode):
    ret_type: str
    name: str
    params: List[Tuple[str, str]]
    body: Block

@dataclass
class VarDecl(ASTNode):
    var_type: str
    name: str
    init_expr: Optional[ASTNode] = None

@dataclass
class LValue(ASTNode):
    name: str
    swizzle: Optional[str] = None

@dataclass
class Assign(ASTNode):
    target: LValue
    expr: ASTNode

@dataclass
class IfStmt(ASTNode):
    condition: ASTNode
    true_block: Block
    false_block: Optional[Block]

@dataclass
class ReturnStmt(ASTNode):
    expr: Optional[ASTNode]

@dataclass
class BinOp(ASTNode):
    op: str
    left: ASTNode
    right: ASTNode

@dataclass
class UnaryOp(ASTNode):
    op: str
    expr: ASTNode

@dataclass
class Call(ASTNode):
    func_name: str
    args: List[ASTNode]

@dataclass
class Number(ASTNode):
    value: Union[int, float]
    is_float: bool

# ==========================================
# 2. Lark Grammar
# ==========================================

grammar = """
    start: func_decl+ -> program

    func_decl: TYPE CNAME "(" [param ("," param)*] ")" block
    param: TYPE CNAME

    ?statement: declaration
              | assignment
              | if_stmt
              | block
              | "return" expr ";" -> return_stmt
              | "return" ";" -> return_void

    block: "{" statement* "}" -> block

    declaration: TYPE CNAME "=" expr ";" -> var_decl
               | TYPE CNAME ";" -> var_decl_uninit

    assignment: lvalue "=" expr ";" -> assign
    if_stmt: "if" "(" expr ")" block ["else" block] -> if_stmt

    ?expr: log_or

    ?log_or: log_and
           | log_or OR log_and -> bin_op
           
    ?log_and: bit_or
            | log_and AND bit_or -> bin_op
            
    ?bit_or: bit_xor
           | bit_or BOR bit_xor -> bin_op
           
    ?bit_xor: bit_and
            | bit_xor BXOR bit_and -> bin_op
            
    ?bit_and: equality
            | bit_and BAND equality -> bin_op
            
    ?equality: comp
             | equality EQ comp -> bin_op
             | equality NEQ comp -> bin_op
             
    ?comp: shift
         | comp LT shift -> bin_op
         | comp GT shift -> bin_op
         | comp LE shift -> bin_op
         | comp GE shift -> bin_op
         
    ?shift: sum
          | shift SHL sum -> bin_op
          | shift SHR sum -> bin_op
         
    ?sum: product
        | sum PLUS product -> bin_op
        | sum MINUS product -> bin_op
        
    ?product: unary
            | product STAR unary -> bin_op
            | product SLASH unary -> bin_op
            
    ?unary: MINUS unary -> unary_op
          | BANG unary -> unary_op
          | atom

    ?atom: NUMBER -> number
         | lvalue
         | CNAME "(" [expr ("," expr)*] ")" -> call
         | "(" expr ")"

    lvalue: CNAME ["." SWIZZLE] -> lvalue

    TYPE.2: "int" | "float" | "vec2" | "vec3" | "vec4" | "void"
    SWIZZLE: /[xyzw]{1,4}/

    OR: "||"
    AND: "&&"
    BOR: "|"
    BXOR: "^"
    BAND: "&"
    EQ: "=="
    NEQ: "!="
    LT: "<"
    GT: ">"
    LE: "<="
    GE: ">="
    SHL: "<<"
    SHR: ">>"
    PLUS: "+"
    MINUS: "-"
    STAR: "*"
    SLASH: "/"
    BANG: "!"

    %import common.CNAME
    %import common.NUMBER
    %import common.WS
    %import common.C_COMMENT
    %import common.CPP_COMMENT
    
    %ignore WS
    %ignore C_COMMENT
    %ignore CPP_COMMENT
"""

# ==========================================
# 3. Transformer (Parse Tree -> AST)
# ==========================================

@v_args(inline=True)
class ShaderTransformer(Transformer):
    def program(self, *funcs):
        return Program(list(funcs))
        
    def func_decl(self, ret_type, name, *args):
        body = args[-1]
        params = []
        for p in args[:-1]:
            if p is not None:
                params.append((str(p[0]), str(p[1])))
        return FuncDecl(str(ret_type), str(name), params, body)
        
    def param(self, p_type, name):
        return [str(p_type), str(name)]
        
    def block(self, *statements):
        return Block(list(statements))
        
    def var_decl(self, var_type, name, expr):
        return VarDecl(str(var_type), str(name), expr)
        
    def var_decl_uninit(self, var_type, name):
        return VarDecl(str(var_type), str(name), None)
        
    def assign(self, target, expr):
        return Assign(target, expr)
        
    def if_stmt(self, condition, true_block, false_block=None):
        return IfStmt(condition, true_block, false_block)

    def return_stmt(self, expr):
        return ReturnStmt(expr)

    def return_void(self):
        return ReturnStmt(None)
        
    def bin_op(self, left, op, right):
        return BinOp(str(op), left, right)
        
    def unary_op(self, op, expr):
        return UnaryOp(str(op), expr)
        
    def call(self, name, *args):
        return Call(str(name), list(args))
        
    def lvalue(self, name, swizzle=None):
        return LValue(str(name), str(swizzle) if swizzle else None)
        
    def number(self, n):
        n_str = str(n)
        is_float = '.' in n_str or 'e' in n_str.lower()
        val = float(n_str) if is_float else int(n_str)
        return Number(val, is_float)

parser = Lark(grammar, parser='lalr', transformer=ShaderTransformer())

# ==========================================
# 4. Intermediate Representation (IR)
# ==========================================

@dataclass
class TACInst:
    op: str
    dest: Optional[str] = None
    src1: Optional[str] = None
    src2: Optional[str] = None
    
    def __repr__(self):
        parts = [self.op]
        if self.dest: parts.append(self.dest)
        if self.src1: parts.append(self.src1)
        if self.src2: parts.append(self.src2)
        return " ".join(parts)


class CallFinder:
    def __init__(self):
        self.has_call = False
    def visit(self, node):
        if isinstance(node, Call) and node.func_name not in ['thread_id', 'float', 'int', 'vec2', 'vec3', 'vec4']:
            self.has_call = True
        elif hasattr(node, '__dict__'):
            for v in vars(node).values():
                if isinstance(v, list):
                    for item in v:
                        if isinstance(item, ASTNode): self.visit(item)
                elif isinstance(v, ASTNode):
                    self.visit(v)

# ==========================================
# 5. Semantic Analyzer & TAC Generator
# ==========================================

class CompileError(Exception):
    pass

class SemanticAnalyzer:
    def __init__(self, enable_inlining=True):
        self.ir: List[TACInst] = []
        self.symtab: Dict[str, str] = {}
        self.temp_count = 0
        self.current_func = None
        
        self.enable_inlining = enable_inlining
        self.functions = {}
        self.divergence_depth = 0  # >0 while inside an if/else divergent region
        self.is_inlining = False
        self.inline_count = 0
        self.inline_prefix = ""
        self.aliases = {}
        self.inline_end_label = None
        self.inline_ret_temp = None

    def emit(self, op: str, dest: str = None, src1: str = None, src2: str = None):
        inst = TACInst(op, dest, src1, src2)
        self.ir.append(inst)
        return inst

    def new_temp(self, var_type: str) -> str:
        name = f"_t{self.temp_count}"
        self.temp_count += 1
        self.symtab[name] = var_type
        return name

    def get_type(self, name: str) -> str:
        base_name = name.split('.')[0]
        if base_name not in self.symtab:
            raise CompileError(f"Undefined variable: {base_name}")
        return self.symtab[base_name]

    def is_float_type(self, var_type: str) -> bool:
        return var_type in ['float', 'vec2', 'vec3', 'vec4']
        
    def _resolve_name(self, name: str) -> str:
        return self.aliases.get(name, name)

    def visit(self, node: Any) -> Tuple[Optional[str], Optional[str]]:
        method_name = f'visit_{type(node).__name__}'
        visitor = getattr(self, method_name, self.generic_visit)
        return visitor(node)

    def generic_visit(self, node: Any):
        raise CompileError(f"No visit method for {type(node).__name__}")

    def visit_Program(self, node):
        for stmt in node.statements:
            if type(stmt).__name__ == 'FuncDecl':
                self.symtab[stmt.name] = stmt.ret_type
                self.functions[stmt.name] = stmt

        funcs = sorted(node.statements, key=lambda f: 0 if getattr(f, 'name', '') == 'main' else 1)
        for stmt in funcs:
            self.visit(stmt)
        return None, None

    def visit_FuncDecl(self, node):
        self.current_func = node.name
        self.symtab[node.name] = node.ret_type
        
        self.emit("LABEL", node.name)
        self.emit("FUNC_START", node.name)
        
        for idx, (p_type, p_name) in enumerate(node.params):
            self.symtab[p_name] = p_type
            arg_name = f"_arg{idx}"
            self.symtab[arg_name] = p_type
            self.emit("MOV", p_name, arg_name) 
            
        self.visit(node.body)
        
        # Don't emit an extra RET if we ended with RET_PIXEL
        if not self.ir or self.ir[-1].op not in ['RET', 'TAIL_CALL', 'RET_PIXEL']:
            self.emit("RET")
            
        return None, None

    def visit_Block(self, node):
        for stmt in node.statements:
            self.visit(stmt)
        return None, None

    def visit_VarDecl(self, node):
        actual_name = f"{self.inline_prefix}{node.name}" if self.is_inlining else node.name
        if self.is_inlining:
            self.aliases[node.name] = actual_name
            
        self.symtab[actual_name] = node.var_type
        
        if node.init_expr:
            val_name, val_type = self.visit(node.init_expr)
            self.emit("MOV", actual_name, val_name)
        return None, None

    def visit_Assign(self, node):
        if node.target.name == 'out_color':
            if self.divergence_depth > 0:
                raise CompileError(
                    "'out_color' cannot be assigned inside a conditional branch: "
                    "RETURN reg cannot execute in a divergent path. "
                    "Compute the pixel value before any 'if' statement and assign out_color unconditionally.")
            expr_name, _ = self.visit(node.expr)
            self.emit("FLUSH")
            self.emit("RET_PIXEL", None, expr_name)
            return None, None

        target_name = self._resolve_name(node.target.name)
        if node.target.swizzle:
            target_name += f".{node.target.swizzle}"
            
        expr_name, expr_type = self.visit(node.expr)
        self.emit("MOV", target_name, expr_name)
        return None, None

    def visit_ReturnStmt(self, node):
        if self.is_inlining:
            if node.expr:
                val_name, val_type = self.visit(node.expr) 
                if self.inline_ret_temp:
                    self.emit("MOV", self.inline_ret_temp, val_name)
            self.emit("JMP", self.inline_end_label)
            return None, None
            
        if node.expr:
            if isinstance(node.expr, Call) and node.expr.func_name not in ['thread_id', 'float', 'int', 'vec2', 'vec3', 'vec4']:
                self._setup_call_args(node.expr)
                self.emit("TAIL_CALL", node.expr.func_name)
                return None, None
                
            val_name, val_type = self.visit(node.expr) 
            self.symtab["_ret0"] = val_type           
            self.emit("MOV", "_ret0", val_name)
            
        self.emit("RET")
        return None, None

    def visit_Number(self, node):
        var_type = 'float' if node.is_float else 'int'
        temp = self.new_temp(var_type)
        self.emit("LOAD_IMM", temp, str(node.value))
        return temp, var_type

    def visit_LValue(self, node):
        full_name = self._resolve_name(node.name)
        base_type = self.get_type(full_name)
        
        if node.swizzle:
            if len(node.swizzle) == 1:
                full_name += f".{node.swizzle * 4}"
            else:
                full_name += f".{node.swizzle}"
                
        return full_name, base_type

    def visit_BinOp(self, node):
        left_val, left_type = self.visit(node.left)
        right_val, right_type = self.visit(node.right)

        is_float = self.is_float_type(left_type)
        op_map = {
            '+': 'FADD' if is_float else 'IADD',
            '-': 'FSUB' if is_float else 'ISUB',
            '*': 'FMUL' if is_float else 'IMUL',
            '/': 'FDIV' if is_float else 'IDIV',
            '&': 'IAND', '|': 'IOR', '^': 'IXOR',
            '<<': 'ISHL', '>>': 'ISHR',
            '==': 'FCMP_EQ' if is_float else 'ICMP_EQ',
            '<': 'FCMP_LT' if is_float else 'ICMP_SLT',
        }

        hw_op = op_map[node.op]
        res_type = 'bool' if node.op in ['==', '!=', '<', '>', '<=', '>='] else left_type
        temp = self.new_temp(res_type)
        self.emit(hw_op, temp, left_val, right_val)
        return temp, res_type

    def _should_inline(self, func_node):
        if not self.enable_inlining: return False
        if len(func_node.body.statements) > 15: return False
        
        finder = CallFinder()
        finder.visit(func_node.body)
        if finder.has_call: return False
        
        return True
        
    def _inline_call(self, func_node, args):
        arg_vals = [self.visit(a)[0] for a in args]
        
        self.inline_count += 1
        self.is_inlining = True
        self.inline_prefix = f"_inl{self.inline_count}_"
        self.inline_end_label = f"INLINE_END_{self.inline_count}"
        
        ret_type = func_node.ret_type
        self.inline_ret_temp = self.new_temp(ret_type) if ret_type != 'void' else None
        old_aliases = self.aliases.copy()
        
        for idx, (p_type, p_name) in enumerate(func_node.params):
            actual_param = f"{self.inline_prefix}{p_name}"
            self.symtab[actual_param] = p_type
            self.aliases[p_name] = actual_param
            self.emit("MOV", actual_param, arg_vals[idx])
            
        self.visit(func_node.body)
        
        self.emit("LABEL", self.inline_end_label)
        self.aliases = old_aliases
        self.is_inlining = False
        
        return self.inline_ret_temp, ret_type

    def visit_Call(self, node):
        if node.func_name == 'thread_id':
            temp = self.new_temp('int')
            self.emit('THREAD_ID', temp)
            return temp, 'int'
        elif node.func_name == 'float':
            arg_val, _ = self.visit(node.args[0])
            temp = self.new_temp('float')
            self.emit('I2F', temp, arg_val)
            return temp, 'float'
        elif node.func_name == 'int':
            arg_val, _ = self.visit(node.args[0])
            temp = self.new_temp('int')
            self.emit('F2I', temp, arg_val)
            return temp, 'int'
        elif node.func_name.startswith('vec'):
            temp = self.new_temp(node.func_name)
            for i, arg_expr in enumerate(node.args):
                arg_val, _ = self.visit(arg_expr)
                comp = ['x', 'y', 'z', 'w'][i]
                self.emit('MOV', f"{temp}.{comp}", arg_val)
            return temp, node.func_name
            
        func_ast = self.functions.get(node.func_name)
        if func_ast and self._should_inline(func_ast):
            return self._inline_call(func_ast, node.args)
            
        self._setup_call_args(node)
        self.emit("CALL", node.func_name)
        
        ret_type = self.symtab.get(node.func_name, 'float')
        if ret_type == 'void':
            return None, 'void'
            
        temp = self.new_temp(ret_type)
        self.symtab["_ret0"] = ret_type  
        self.emit("MOV", temp, "_ret0")
        return temp, ret_type

    def _setup_call_args(self, call_node):
        for idx, arg_expr in enumerate(call_node.args):
            val_name, val_type = self.visit(arg_expr) 
            arg_name = f"_arg{idx}"
            self.symtab[arg_name] = val_type          
            self.emit("MOV", arg_name, val_name)

    def visit_IfStmt(self, node):
        cond_val, cond_type = self.visit(node.condition)
        self.emit("FLUSH")
        label_if = f"IF_TRUE_{self.temp_count}"
        label_reconv = f"RECONV_{self.temp_count}"
        self.temp_count += 1

        self.emit("SSY", label_reconv)
        self.emit("BRA_DIV", label_if, cond_val)

        self.divergence_depth += 1
        if node.false_block:
            self.visit(node.false_block)
        self.emit("SYNC")

        self.emit("LABEL", label_if)
        self.visit(node.true_block)
        self.emit("SYNC")
        self.divergence_depth -= 1

        self.emit("LABEL", label_reconv)
        self.emit("FLUSH")
        return None, None

# ==========================================
# 6. Instruction Selection (Lowering)
# ==========================================

class InstructionSelector:
    def __init__(self, semantic_analyzer):
        self.sa = semantic_analyzer
        self.lowered_ir: List[TACInst] = []
        self.current_func = None

    def lower(self):
        leaf_status = {}
        curr = None
        for inst in self.sa.ir:
            if inst.op == 'FUNC_START':
                curr = inst.dest
                leaf_status[curr] = True
            elif inst.op == 'CALL':
                leaf_status[curr] = False

        for inst in self.sa.ir:
            if inst.op == 'FUNC_START':
                self.current_func = inst.dest
                if not leaf_status[self.current_func] and self.current_func != 'main':
                    self.lowered_ir.append(TACInst("PUSH_L"))
            elif inst.op == 'CALL':
                self.lowered_ir.append(TACInst("BRA_L", inst.dest))
            elif inst.op == 'TAIL_CALL':
                if not leaf_status[self.current_func] and self.current_func != 'main':
                    self.lowered_ir.append(TACInst("POP_L"))
                self.lowered_ir.append(TACInst("JMP", inst.dest))
            elif inst.op == 'RET_PIXEL':
                # --- NEW LOWERING FOR RETURN REG ---
                self.lowered_ir.append(TACInst("RETURN", None, inst.src1))
            elif inst.op == 'RET':
                if self.current_func == 'main':
                    self.lowered_ir.append(TACInst("FLUSH"))
                    self.lowered_ir.append(TACInst("RETURN")) # Bare return
                else:
                    if not leaf_status[self.current_func]:
                        self.lowered_ir.append(TACInst("POP_L"))
                    self.lowered_ir.append(TACInst("BRA_X"))
            elif inst.op == 'LOAD_IMM':
                self._lower_load_imm(inst)
            elif inst.op == 'FDIV':
                self._lower_fdiv(inst)
            else:
                self.lowered_ir.append(inst)
                
        self.sa.ir = self.lowered_ir

    def _lower_load_imm(self, inst):
        dest = inst.dest
        val_str = inst.src1
        is_float = '.' in val_str or 'e' in val_str.lower()
        
        if is_float:
            val_int = struct.unpack('<I', struct.pack('<f', float(val_str)))[0]
        else:
            val_int = int(val_str) & 0xFFFFFFFF
            
        lo = val_int & 0xFFFF
        hi = (val_int >> 16) & 0xFFFF
        
        self.lowered_ir.append(TACInst("LDI_LO", dest, f"0x{lo:04X}"))
        if hi != 0:
            self.lowered_ir.append(TACInst("LDI_HI", dest, f"0x{hi:04X}"))

    def _lower_fdiv(self, inst):
        temp_rcp = self.sa.new_temp('float')
        self.lowered_ir.append(TACInst("FRCP", temp_rcp, inst.src2))
        self.lowered_ir.append(TACInst("FMUL", inst.dest, inst.src1, temp_rcp))

# ==========================================
# 7. Register Allocation & Peephole Cleanup
# ==========================================

class RegisterAllocator:
    def __init__(self, semantic_analyzer):
        self.sa = semantic_analyzer
        self.ir = self.sa.ir
        
        self.live_in = [set() for _ in self.ir]
        self.live_out = [set() for _ in self.ir]
        
        self.interference_v = {}
        self.interference_p = {}
        self.allocation = {}

    def _get_base_var(self, name: str) -> Optional[str]:
        if not name or name.startswith('0x') or name.startswith('IF_TRUE') or name.startswith('RECONV') or name.startswith('INLINE'):
            return None
        return name.split('.')[0]

    def _get_use_def(self, inst: TACInst) -> Tuple[set, set]:
        uses, defs = set(), set()
        
        if inst.op in ['JMP', 'SSY', 'FLUSH', 'SYNC', 'LABEL', 'PUSH_L', 'POP_L', 'BRA_L', 'BRA_X']:
            pass
        elif inst.op == 'BRA_DIV':
            u = self._get_base_var(inst.dest) 
            if u: uses.add(u)
        elif inst.op == 'RETURN':
            # --- NEW LIVENESS SUPPORT FOR RETURN REG ---
            u = self._get_base_var(inst.src1)
            if u: uses.add(u)
        else:
            d = self._get_base_var(inst.dest)
            s1 = self._get_base_var(inst.src1)
            s2 = self._get_base_var(inst.src2)
            if d: 
                defs.add(d)
                if inst.dest and '.' in inst.dest:
                    uses.add(d)
            if s1: uses.add(s1)
            if s2: uses.add(s2)
            
        return uses, defs

    def build_cfg_and_liveness(self):
        labels = {inst.dest: i for i, inst in enumerate(self.ir) if inst.op == 'LABEL'}
        successors = [[] for _ in self.ir]
        
        for i, inst in enumerate(self.ir):
            if inst.op in ['RETURN', 'BRA_X']:
                continue
            if inst.op in ['JMP', 'BRA_DIV']:
                target = inst.dest if inst.op == 'JMP' else inst.src1
                if target in labels:
                    successors[i].append(labels[target])
            if inst.op != 'JMP' and i + 1 < len(self.ir):
                successors[i].append(i + 1)

        changed = True
        while changed:
            changed = False
            for i in range(len(self.ir) - 1, -1, -1):
                uses, defs = self._get_use_def(self.ir[i])
                
                new_out = set()
                for succ in successors[i]:
                    new_out.update(self.live_in[succ])
                self.live_out[i] = new_out
                
                new_in = uses.union(new_out - defs)
                if new_in != self.live_in[i]:
                    self.live_in[i] = new_in
                    changed = True

    def build_interference_graph(self):
        for out_set in self.live_out:
            for var in out_set:
                v_type = self.sa.symtab.get(var, 'float')
                graph = self.interference_p if v_type == 'bool' else self.interference_v
                if var not in graph:
                    graph[var] = set()

        for out_set in self.live_out:
            active_vars = list(out_set)
            for i in range(len(active_vars)):
                for j in range(i + 1, len(active_vars)):
                    v1, v2 = active_vars[i], active_vars[j]
                    type1 = self.sa.symtab.get(v1, 'float')
                    type2 = self.sa.symtab.get(v2, 'float')
                    
                    if type1 == 'bool' and type2 == 'bool':
                        self.interference_p[v1].add(v2)
                        self.interference_p[v2].add(v1)
                    elif type1 != 'bool' and type2 != 'bool':
                        self.interference_v[v1].add(v2)
                        self.interference_v[v2].add(v1)

    def color_graph(self, graph, prefix, max_colors=16):
        nodes = sorted(graph.keys(), key=lambda n: len(graph[n]), reverse=True)
        for node in nodes:
            used_colors = set()
            for neighbor in graph[node]:
                if neighbor in self.allocation:
                    used_colors.add(int(self.allocation[neighbor][1:]))
            
            for color in range(max_colors):
                if color not in used_colors:
                    self.allocation[node] = f"{prefix}{color}"
                    break
            else:
                raise CompileError(f"Register Spillage! Ran out of {prefix} registers.")

    def allocate(self):
        self.build_cfg_and_liveness()
        self.build_interference_graph()
        self.color_graph(self.interference_v, 'v', 16)
        self.color_graph(self.interference_p, 'p', 16)

    def rewrite_ir(self):
        final_ir = []
        for inst in self.ir:
            def map_reg(r):
                if not r: return r
                base = self._get_base_var(r)
                if base in self.allocation:
                    return r.replace(base, self.allocation[base])
                return r

            new_dest = map_reg(inst.dest)
            new_src1 = map_reg(inst.src1)
            new_src2 = map_reg(inst.src2)
            
            is_redundant = False
            
            if inst.op == 'MOV':
                db = self._get_base_var(new_dest)
                s1b = self._get_base_var(new_src1)
                
                if db is not None and db == s1b:
                    if new_src1 and '.' not in new_src1:
                        is_redundant = True
                    elif new_dest == new_src1:
                        is_redundant = True
                    elif new_dest and new_src1 and '.' in new_dest and '.' in new_src1:
                        d_mask = new_dest.split('.')[1]
                        s_swiz = new_src1.split('.')[1]
                        if len(d_mask) == 1 and s_swiz == d_mask * 4:
                            is_redundant = True

            if inst.op == 'FLUSH' and final_ir and final_ir[-1].op == 'FLUSH':
                is_redundant = True

            if not is_redundant:
                final_ir.append(TACInst(inst.op, new_dest, new_src1, new_src2))
                
        return final_ir

# ==========================================
# 8. Code Emission
# ==========================================

class AssemblyEmitter:
    def __init__(self, physical_ir: List[TACInst]):
        self.ir = physical_ir

    def generate(self) -> str:
        lines = []
        for inst in self.ir:
            if inst.op == 'LABEL':
                lines.append(f"{inst.dest}:")
                continue

            args = []
            if inst.op == 'RETURN':
                # --- NEW FORMATTING SUPPORT FOR RETURN REG ---
                if inst.src1 is not None:
                    args.append(str(inst.src1))
            else:
                if inst.dest is not None: args.append(str(inst.dest))
                if inst.src1 is not None: args.append(str(inst.src1))
                if inst.src2 is not None: args.append(str(inst.src2))

            if args:
                formatted_args = ", ".join(args)
                lines.append(f"    {inst.op:<10} {formatted_args}")
            else:
                lines.append(f"    {inst.op}")
                
        return "\n".join(lines)


# ==========================================
# 9. Execution Pipeline
# ==========================================
if __name__ == "__main__":
    shader_code = """
    vec4 recursive_blend(int step, vec4 color) {
        if (step == 0) {
            return color;
        }
        color.y = color.y + 0.1;
        return recursive_blend(step - 1, color); 
    }

    vec4 adjust_brightness(vec4 color, float amount) {
        vec4 temp = color;
        temp.x = temp.x + amount;
        temp.y = temp.y + amount;
        temp.z = temp.z + amount;
        return temp;
    }

    void main() {
        int tid = thread_id();
        int x = tid & 31;
        float fx = float(x);
        
        vec4 base_color;
        base_color.xyzw = vec4(fx / 32.0, 0.0, 0.0, 1.0);
        
        vec4 blended = recursive_blend(5, base_color);
        out_color = adjust_brightness(blended, 0.2);
    }
    """

    try:
        print("1. Parsing AST...")
        ast = parser.parse(shader_code)
        
        print("2. Semantic Analysis...")
        semantic = SemanticAnalyzer(enable_inlining=True)
        semantic.visit(ast)
        
        print("3. Instruction Selection...")
        selector = InstructionSelector(semantic)
        selector.lower()
        
        print("4. Register Allocation & Cleanup...")
        allocator = RegisterAllocator(semantic)
        allocator.allocate()
        physical_ir = allocator.rewrite_ir()
        
        print("5. Code Emission...")
        emitter = AssemblyEmitter(physical_ir)
        final_assembly = emitter.generate()
        
        print("\n================ FINAL ASSEMBLY ================\n")
        print(final_assembly)
        print("\n================================================")
            
    except CompileError as e:
        print(f"\n[!] Compilation Failed: {e}")
    except Exception as e:
        print(f"\n[!] Parser/Internal Error: {e}")
