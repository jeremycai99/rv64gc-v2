/*
 * Dhrystone 2.1 header — minimal baremetal version.
 */
#ifndef DHRY_H
#define DHRY_H

#include <string.h>

typedef int    Rec_Type;
typedef int    Enumeration;

#define Ident_1 0
#define Ident_2 1
#define Ident_3 2
#define Ident_4 3
#define Ident_5 4

typedef char Str_30[31];
typedef char Str_6[7];

typedef struct record {
    struct record *Ptr_Comp;
    Enumeration    Discr;
    union {
        struct {
            Enumeration Enum_Comp;
            int         Int_Comp;
            Str_30      Str_Comp;
        } var_1;
        struct {
            Enumeration E_Comp_2;
            Str_30      Str_2_Comp;
        } var_2;
        struct {
            char        Ch_1_Comp;
            char        Ch_2_Comp;
        } var_3;
    } variant;
} Rec_Type_Struct, *Rec_Pointer;

/* Dhrystone functions */
void Proc_1(Rec_Pointer Ptr_Val_Par);
void Proc_2(int *Int_Par_Ref);
void Proc_3(Rec_Pointer *Ptr_Ref_Par);
void Proc_4(void);
void Proc_5(void);
void Proc_6(Enumeration Enum_Val_Par, Enumeration *Enum_Ref_Par);
void Proc_7(int Int_1_Par_Val, int Int_2_Par_Val, int *Int_Par_Ref);
void Proc_8(int Arr_1_Par_Ref[], int Arr_2_Par_Ref[][50],
            int Int_1_Par_Val, int Int_2_Par_Val);
Enumeration Func_1(char Ch_1_Par_Val, char Ch_2_Par_Val);
int Func_2(Str_30 Str_1_Par_Ref, Str_30 Str_2_Par_Ref);
int Func_3(Enumeration Enum_Par_Val);

#endif
