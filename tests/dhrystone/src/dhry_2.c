/*
 * Dhrystone 2.1 — procedures module.
 */
#include "dhry.h"

extern Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
extern int         Int_Glob;
extern int         Bool_Glob;
extern char        Ch_1_Glob, Ch_2_Glob;
extern int         Arr_1_Glob[];
extern int         Arr_2_Glob[][50];

void Proc_1(Rec_Pointer Ptr_Val_Par)
{
    Rec_Pointer Next_Record = Ptr_Val_Par->Ptr_Comp;

    *Ptr_Val_Par->Ptr_Comp = *Ptr_Glob;

    Ptr_Val_Par->variant.var_1.Int_Comp = 5;
    Next_Record->variant.var_1.Int_Comp =
        Ptr_Val_Par->variant.var_1.Int_Comp;
    Next_Record->Ptr_Comp = Ptr_Val_Par->Ptr_Comp;

    Proc_3(&Next_Record->Ptr_Comp);

    if (Next_Record->Discr == Ident_1) {
        Next_Record->variant.var_1.Int_Comp = 6;
        Proc_6(Ptr_Val_Par->variant.var_1.Enum_Comp,
               &Next_Record->variant.var_1.Enum_Comp);
        Next_Record->Ptr_Comp = Ptr_Glob->Ptr_Comp;
        Proc_7(Next_Record->variant.var_1.Int_Comp, 10,
               &Next_Record->variant.var_1.Int_Comp);
    } else {
        *Ptr_Val_Par = *Ptr_Val_Par->Ptr_Comp;
    }
}

void Proc_2(int *Int_Par_Ref)
{
    int Int_Loc;
    Enumeration Enum_Loc;

    Int_Loc = *Int_Par_Ref + 10;
    do {
        if (Ch_1_Glob == 'A') {
            Int_Loc -= 1;
            *Int_Par_Ref = Int_Loc - Int_Glob;
            Enum_Loc = Ident_1;
        }
    } while (Enum_Loc != Ident_1);
}

void Proc_3(Rec_Pointer *Ptr_Ref_Par)
{
    if (Ptr_Glob != 0)
        *Ptr_Ref_Par = Ptr_Glob->Ptr_Comp;
    Proc_7(10, Int_Glob, &Ptr_Glob->variant.var_1.Int_Comp);
}

void Proc_4(void)
{
    int Bool_Loc;
    Bool_Loc = Ch_1_Glob == 'A';
    Bool_Glob = Bool_Loc | Bool_Glob;
    Ch_2_Glob = 'B';
}

void Proc_5(void)
{
    Ch_1_Glob = 'A';
    Bool_Glob = 0;
}

void Proc_6(Enumeration Enum_Val_Par, Enumeration *Enum_Ref_Par)
{
    *Enum_Ref_Par = Enum_Val_Par;
    if (!Func_3(Enum_Val_Par))
        *Enum_Ref_Par = Ident_4;
    switch (Enum_Val_Par) {
        case Ident_1: *Enum_Ref_Par = Ident_1; break;
        case Ident_2:
            if (Int_Glob > 100) *Enum_Ref_Par = Ident_1;
            else                *Enum_Ref_Par = Ident_4;
            break;
        case Ident_3: *Enum_Ref_Par = Ident_2; break;
        case Ident_4: break;
        case Ident_5: *Enum_Ref_Par = Ident_3; break;
    }
}

void Proc_7(int Int_1_Par_Val, int Int_2_Par_Val, int *Int_Par_Ref)
{
    int Int_Loc;
    Int_Loc = Int_1_Par_Val + 2;
    *Int_Par_Ref = Int_2_Par_Val + Int_Loc;
}

void Proc_8(int Arr_1_Par_Ref[], int Arr_2_Par_Ref[][50],
            int Int_1_Par_Val, int Int_2_Par_Val)
{
    int Int_Index;
    int Int_Loc;

    Int_Loc = Int_1_Par_Val + 5;
    Arr_1_Par_Ref[Int_Loc] = Int_2_Par_Val;
    Arr_1_Par_Ref[Int_Loc + 1] = Arr_1_Par_Ref[Int_Loc];
    Arr_1_Par_Ref[Int_Loc + 30] = Int_Loc;
    for (Int_Index = Int_Loc; Int_Index <= Int_Loc + 1; ++Int_Index)
        Arr_2_Par_Ref[Int_Loc][Int_Index] = Int_Loc;
    Arr_2_Par_Ref[Int_Loc][Int_Loc - 1] += 1;
    Arr_2_Par_Ref[Int_Loc + 20][Int_Loc] = Arr_1_Par_Ref[Int_Loc];
    Int_Glob = 5;
}

Enumeration Func_1(char Ch_1_Par_Val, char Ch_2_Par_Val)
{
    char Ch_1_Loc, Ch_2_Loc;
    Ch_1_Loc = Ch_1_Par_Val;
    Ch_2_Loc = Ch_1_Loc;
    if (Ch_2_Loc != Ch_2_Par_Val)
        return Ident_1;
    else {
        Ch_1_Glob = Ch_1_Loc;
        return Ident_2;
    }
}

int Func_2(Str_30 Str_1_Par_Ref, Str_30 Str_2_Par_Ref)
{
    int Int_Loc;
    char Ch_Loc;

    Int_Loc = 2;
    while (Int_Loc <= 2) {
        if (Func_1(Str_1_Par_Ref[Int_Loc],
                    Str_2_Par_Ref[Int_Loc + 1]) == Ident_1) {
            Ch_Loc = 'A';
            Int_Loc += 1;
        }
    }
    if (Ch_Loc >= 'W' && Ch_Loc < 'Z')
        Int_Loc = 7;
    if (Ch_Loc == 'R')
        return 1;
    else {
        if (strcmp(Str_1_Par_Ref, Str_2_Par_Ref) > 0) {
            Int_Loc += 7;
            Int_Glob = Int_Loc;
            return 1;
        } else
            return 0;
    }
}

int Func_3(Enumeration Enum_Par_Val)
{
    Enumeration Enum_Loc;
    Enum_Loc = Enum_Par_Val;
    if (Enum_Loc == Ident_3)
        return 1;
    else
        return 0;
}
