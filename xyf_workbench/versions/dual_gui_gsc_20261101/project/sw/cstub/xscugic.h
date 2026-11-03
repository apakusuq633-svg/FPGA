/* See the comment at the top of sw/cstub/xil_io.h for what this directory is.
 *
 * Only needed by sw/ps_main.c when USE_IRQ=1 (the default is the polling path, which
 * needs no GIC at all). The real driver pulls in xstatus.h / xparameters.h, so this
 * one does too -- that is where XST_SUCCESS and the device ids come from. */
#ifndef XSCUGIC_H
#define XSCUGIC_H

#include "xil_io.h"
#include "xstatus.h"
#include "xparameters.h"

typedef struct { int dummy; } XScuGic;
typedef struct { int CpuBaseAddress; } XScuGic_Config;

#define XIL_EXCEPTION_ID_INT 0

typedef void (*Xil_ExceptionHandler)(void *);

static inline XScuGic_Config *XScuGic_LookupConfig(int i) { (void)i; return 0; }
static inline int  XScuGic_CfgInitialize(XScuGic *g, XScuGic_Config *c, int b) { (void)g;(void)c;(void)b; return XST_SUCCESS; }
static inline void XScuGic_SetPriorityTriggerType(XScuGic *g, int id, unsigned char p, unsigned char t) { (void)g;(void)id;(void)p;(void)t; }
static inline int  XScuGic_Connect(XScuGic *g, int id, Xil_ExceptionHandler h, void *c) { (void)g;(void)id;(void)h;(void)c; return XST_SUCCESS; }
static inline void XScuGic_Enable(XScuGic *g, int id) { (void)g;(void)id; }
static inline void XScuGic_InterruptHandler(void *c) { (void)c; }
static inline void Xil_ExceptionInit(void) {}
static inline void Xil_ExceptionRegisterHandler(int id, Xil_ExceptionHandler h, void *c) { (void)id;(void)h;(void)c; }
static inline void Xil_ExceptionEnable(void) {}

#endif
