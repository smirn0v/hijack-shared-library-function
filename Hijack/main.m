//
//  main.m
//  Hijack
//
//  Created by Alexander Smirnov on 17.04.2022.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

#include "../armadillo/source/armadillo.h"
#include <sys/mman.h>

#if 0

0x10214470c: 0xa9bf7bfd   stp    x29, x30, [sp, #-0x10]!
0x102144710: 0x910003fd   mov    x29, sp
0x102144714: 0x52800000   mov    w0, #0x0
0x102144718: 0xd2800001   mov    x1, #0x0
0x10214471c: 0xd2800002   mov    x2, #0x0
0x102144720: 0x94004919   bl     0x102156b84               ; symbol stub for: write
0x102144724: 0xa8c17bfd   ldp    x29, x30, [sp], #0x10
0x102144728: 0xd65f03c0   ret

#endif

#define kOFFSET_FROM_DUMMY_START 20

void dummy_function_call(void) {
    write(0, 0, 0);
}

int (*original_function)(int __fd, const void * __buf, size_t __nbyte);

int our_function(int __fd, const void * __buf, size_t __nbyte) {
    printf("write(fd = %d, buf = %p, nbyte = %zu)\n", __fd, __buf, __nbyte);
    return original_function(__fd, __buf, __nbyte);
}

uint64_t function_trampoline_addr(void) {
  
    uint64_t addr = ((uint64_t)&dummy_function_call)+kOFFSET_FROM_DUMMY_START;
    uint32_t opcode = *(uint32_t*)(addr);
    struct ad_insn *instruction=NULL;
    
    if(ArmadilloDisassemble(opcode, (unsigned long)addr, &instruction)==0) {
        if(instruction->instr_id == AD_INSTR_BL && instruction->num_operands==1) {
            addr = instruction->operands->op_imm.bits;
            ArmadilloDone(&instruction);
            return addr;
        }
    }
    
    return 0;
}

void substitute_function(void) {
    uint64_t function_trampoline = function_trampoline_addr();
    struct ad_insn *instruction=NULL;
    unsigned int opcode = *((unsigned int*)function_trampoline);
    
    unsigned long got_plt_addr;
    
    int ret = ArmadilloDisassemble(opcode, (unsigned long)function_trampoline, &instruction);
    if(ret!=0 || instruction->instr_id != AD_INSTR_ADRP || instruction->num_operands!=2) {
        return;
    }

    got_plt_addr = instruction->operands[1].op_imm.bits;
    ArmadilloDone(&instruction);
            
    // AArch64 имеет фиксированный размер инструкций в 4 байта
    opcode = *(unsigned int*)((char*)function_trampoline+4);
    ret = ArmadilloDisassemble(opcode, (unsigned long)((char*)function_trampoline+4), &instruction);
    if(ret!=0 || instruction->instr_id != AD_INSTR_LDR || instruction->num_operands!=3 || instruction->operands[2].type!=AD_OP_IMM) {
        return;
    }
    
    got_plt_addr += instruction->operands[2].op_imm.bits;
    
    // Спасаемся от RELRO. Помечаем нужную страницу памяти доступной на запись
    // Размер страницы 4096 байт.  Поэтому 12 бит смещения.
    ret = mprotect((void*)((got_plt_addr>>12)<<12), 1<<12, PROT_WRITE|PROT_READ);
    if(ret != 0) {
        return;
    }
    
    original_function = (void*)(*(uint64_t*)got_plt_addr);
    *(uint64_t*)got_plt_addr = (uint64_t)&our_function;
}

int main(int argc, char * argv[]) {
    
    write(0,NULL,0);
    substitute_function();
    write(1,NULL,2);
    
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
