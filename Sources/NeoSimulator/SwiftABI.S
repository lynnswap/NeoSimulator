#if !defined(__arm64__)
#error NeoSimulator currently supports arm64 only
#endif

.text
.p2align 2

.globl _XSHSwiftCallVoidMethod
_XSHSwiftCallVoidMethod:
    stp x29, x30, [sp, #-32]!
    stp x20, x19, [sp, #16]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    blr x19
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl _XSHSwiftCallBoolMethod
_XSHSwiftCallBoolMethod:
    stp x29, x30, [sp, #-32]!
    stp x20, x19, [sp, #16]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    and w0, w2, #1
    blr x19
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl _XSHSwiftCallCGFloatGetter
_XSHSwiftCallCGFloatGetter:
    stp x29, x30, [sp, #-32]!
    stp x20, x19, [sp, #16]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    blr x19
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl _XSHSwiftSetAngleMeasurement
_XSHSwiftSetAngleMeasurement:
    stp x29, x30, [sp, #-48]!
    stp x20, x19, [sp, #16]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    // Measurement<NSUnitAngle> stores the unit reference followed by Double.
    str x2, [sp, #32]
    str d0, [sp, #40]
    add x0, sp, #32
    blr x19
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

.globl _XSHSwiftCallCGSizeMethod
_XSHSwiftCallCGSizeMethod:
    stp x29, x30, [sp, #-32]!
    stp x20, x19, [sp, #16]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    // The homogeneous CGSize argument remains in d0/d1.
    blr x19
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl _XSHSwiftDisconnect
_XSHSwiftDisconnect:
    stp x29, x30, [sp, #-32]!
    stp x20, x19, [sp, #16]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    // disconnect(completion:) receives nil for the optional closure.
    mov x0, #0
    mov x1, #0
    blr x19
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
