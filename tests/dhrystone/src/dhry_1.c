/*
 * Dhrystone 2.1 — main module (baremetal, no printf/timing).
 * Adapted from the original by Reinhold P. Weicker.
 */
#include "dhry.h"

/* Global variables */
Rec_Pointer     Ptr_Glob, Next_Ptr_Glob;
int             Int_Glob;
int             Bool_Glob;
char            Ch_1_Glob, Ch_2_Glob;
int             Arr_1_Glob[50];
int             Arr_2_Glob[50][50];

Rec_Type_Struct Rec_Glob_Buf, Next_Rec_Glob_Buf;

#ifndef NUM_RUNS
#define NUM_RUNS 100
#endif

volatile int dhry_result;

int main(void)
{
    int         Int_1_Loc, Int_2_Loc, Int_3_Loc;
    char        Ch_Index;
    Enumeration Enum_Loc;
    Str_30      Str_1_Loc, Str_2_Loc;
    int         Run_Index;

    Next_Ptr_Glob = &Next_Rec_Glob_Buf;
    Ptr_Glob = &Rec_Glob_Buf;

    Ptr_Glob->Ptr_Comp                    = Next_Ptr_Glob;
    Ptr_Glob->Discr                       = Ident_1;
    Ptr_Glob->variant.var_1.Enum_Comp     = Ident_3;
    Ptr_Glob->variant.var_1.Int_Comp      = 40;
    strcpy(Ptr_Glob->variant.var_1.Str_Comp,
           "DHRYSTONE PROGRAM, SOME STRING");

    strcpy(Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");

    Arr_2_Glob[8][7] = 10;

    for (Run_Index = 1; Run_Index <= NUM_RUNS; ++Run_Index) {
        Proc_5();
        Proc_4();

        Int_1_Loc = 2;
        Int_2_Loc = 3;
        strcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");

        Enum_Loc = Ident_2;
        Bool_Glob = !Func_2(Str_1_Loc, Str_2_Loc);

        while (Int_1_Loc < Int_2_Loc) {
            Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
            Proc_7(Int_1_Loc, Int_2_Loc, &Int_3_Loc);
            Int_1_Loc += 1;
        }

        Proc_8(Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
        Proc_1(Ptr_Glob);

        for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index) {
            if (Enum_Loc == Func_1(Ch_Index, 'C'))
                Proc_6(Ident_1, &Enum_Loc);
        }

        Int_2_Loc = Int_2_Loc * Int_1_Loc;
        Int_1_Loc = Int_2_Loc / Int_3_Loc;
        Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;

        Proc_2(&Int_1_Loc);
    }

    /* Store result so optimizer doesn't remove the loop. */
    dhry_result = Int_1_Loc + Int_2_Loc + Int_Glob + Bool_Glob;

    /* Return 0 = PASS (crt0 writes 1 to tohost). */
    return (Int_Glob == 5 && Bool_Glob == 1 &&
            Ch_1_Glob == 'A' && Ch_2_Glob == 'B') ? 0 : 1;
}
