
tests/coremark/coremark.elf:     file format elf64-littleriscv


Disassembly of section .text.start:

0000000080000000 <_start>:
    80000000:	00001137          	lui	sp,0x1
    80000004:	8011011b          	addiw	sp,sp,-2047 # 801 <_start-0x7ffff7ff>
    80000008:	0152                	slli	sp,sp,0x14
    8000000a:	1141                	addi	sp,sp,-16
    8000000c:	00004517          	auipc	a0,0x4
    80000010:	79450513          	addi	a0,a0,1940 # 800047a0 <seed2_volatile>
    80000014:	00004597          	auipc	a1,0x4
    80000018:	79c58593          	addi	a1,a1,1948 # 800047b0 <__bss_end>
    8000001c:	28b57063          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000020:	00053023          	sd	zero,0(a0)
    80000024:	0521                	addi	a0,a0,8
    80000026:	26b57b63          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000002a:	00053023          	sd	zero,0(a0)
    8000002e:	0521                	addi	a0,a0,8
    80000030:	26b57663          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000034:	00053023          	sd	zero,0(a0)
    80000038:	0521                	addi	a0,a0,8
    8000003a:	26b57163          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000003e:	00053023          	sd	zero,0(a0)
    80000042:	0521                	addi	a0,a0,8
    80000044:	24b57c63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000048:	00053023          	sd	zero,0(a0)
    8000004c:	0521                	addi	a0,a0,8
    8000004e:	24b57763          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000052:	00053023          	sd	zero,0(a0)
    80000056:	0521                	addi	a0,a0,8
    80000058:	24b57263          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000005c:	00053023          	sd	zero,0(a0)
    80000060:	0521                	addi	a0,a0,8
    80000062:	22b57d63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000066:	00053023          	sd	zero,0(a0)
    8000006a:	0521                	addi	a0,a0,8
    8000006c:	22b57863          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000070:	00053023          	sd	zero,0(a0)
    80000074:	0521                	addi	a0,a0,8
    80000076:	22b57363          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000007a:	00053023          	sd	zero,0(a0)
    8000007e:	0521                	addi	a0,a0,8
    80000080:	20b57e63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000084:	00053023          	sd	zero,0(a0)
    80000088:	0521                	addi	a0,a0,8
    8000008a:	20b57963          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000008e:	00053023          	sd	zero,0(a0)
    80000092:	0521                	addi	a0,a0,8
    80000094:	20b57463          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000098:	00053023          	sd	zero,0(a0)
    8000009c:	0521                	addi	a0,a0,8
    8000009e:	1eb57f63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000a2:	00053023          	sd	zero,0(a0)
    800000a6:	0521                	addi	a0,a0,8
    800000a8:	1eb57a63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000ac:	00053023          	sd	zero,0(a0)
    800000b0:	0521                	addi	a0,a0,8
    800000b2:	1eb57563          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000b6:	00053023          	sd	zero,0(a0)
    800000ba:	0521                	addi	a0,a0,8
    800000bc:	1eb57063          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000c0:	00053023          	sd	zero,0(a0)
    800000c4:	0521                	addi	a0,a0,8
    800000c6:	1cb57b63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000ca:	00053023          	sd	zero,0(a0)
    800000ce:	0521                	addi	a0,a0,8
    800000d0:	1cb57663          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000d4:	00053023          	sd	zero,0(a0)
    800000d8:	0521                	addi	a0,a0,8
    800000da:	1cb57163          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000de:	00053023          	sd	zero,0(a0)
    800000e2:	0521                	addi	a0,a0,8
    800000e4:	1ab57c63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000e8:	00053023          	sd	zero,0(a0)
    800000ec:	0521                	addi	a0,a0,8
    800000ee:	1ab57763          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000f2:	00053023          	sd	zero,0(a0)
    800000f6:	0521                	addi	a0,a0,8
    800000f8:	1ab57263          	bgeu	a0,a1,8000029c <_start+0x29c>
    800000fc:	00053023          	sd	zero,0(a0)
    80000100:	0521                	addi	a0,a0,8
    80000102:	18b57d63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000106:	00053023          	sd	zero,0(a0)
    8000010a:	0521                	addi	a0,a0,8
    8000010c:	18b57863          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000110:	00053023          	sd	zero,0(a0)
    80000114:	0521                	addi	a0,a0,8
    80000116:	18b57363          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000011a:	00053023          	sd	zero,0(a0)
    8000011e:	0521                	addi	a0,a0,8
    80000120:	16b57e63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000124:	00053023          	sd	zero,0(a0)
    80000128:	0521                	addi	a0,a0,8
    8000012a:	16b57963          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000012e:	00053023          	sd	zero,0(a0)
    80000132:	0521                	addi	a0,a0,8
    80000134:	16b57463          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000138:	00053023          	sd	zero,0(a0)
    8000013c:	0521                	addi	a0,a0,8
    8000013e:	14b57f63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000142:	00053023          	sd	zero,0(a0)
    80000146:	0521                	addi	a0,a0,8
    80000148:	14b57a63          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000014c:	00053023          	sd	zero,0(a0)
    80000150:	0521                	addi	a0,a0,8
    80000152:	14b57563          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000156:	00053023          	sd	zero,0(a0)
    8000015a:	0521                	addi	a0,a0,8
    8000015c:	14b57063          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000160:	00053023          	sd	zero,0(a0)
    80000164:	0521                	addi	a0,a0,8
    80000166:	12b57b63          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000016a:	00053023          	sd	zero,0(a0)
    8000016e:	0521                	addi	a0,a0,8
    80000170:	12b57663          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000174:	00053023          	sd	zero,0(a0)
    80000178:	0521                	addi	a0,a0,8
    8000017a:	12b57163          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000017e:	00053023          	sd	zero,0(a0)
    80000182:	0521                	addi	a0,a0,8
    80000184:	10b57c63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000188:	00053023          	sd	zero,0(a0)
    8000018c:	0521                	addi	a0,a0,8
    8000018e:	10b57763          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000192:	00053023          	sd	zero,0(a0)
    80000196:	0521                	addi	a0,a0,8
    80000198:	10b57263          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000019c:	00053023          	sd	zero,0(a0)
    800001a0:	0521                	addi	a0,a0,8
    800001a2:	0eb57d63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001a6:	00053023          	sd	zero,0(a0)
    800001aa:	0521                	addi	a0,a0,8
    800001ac:	0eb57863          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001b0:	00053023          	sd	zero,0(a0)
    800001b4:	0521                	addi	a0,a0,8
    800001b6:	0eb57363          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001ba:	00053023          	sd	zero,0(a0)
    800001be:	0521                	addi	a0,a0,8
    800001c0:	0cb57e63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001c4:	00053023          	sd	zero,0(a0)
    800001c8:	0521                	addi	a0,a0,8
    800001ca:	0cb57963          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001ce:	00053023          	sd	zero,0(a0)
    800001d2:	0521                	addi	a0,a0,8
    800001d4:	0cb57463          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001d8:	00053023          	sd	zero,0(a0)
    800001dc:	0521                	addi	a0,a0,8
    800001de:	0ab57f63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001e2:	00053023          	sd	zero,0(a0)
    800001e6:	0521                	addi	a0,a0,8
    800001e8:	0ab57a63          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001ec:	00053023          	sd	zero,0(a0)
    800001f0:	0521                	addi	a0,a0,8
    800001f2:	0ab57563          	bgeu	a0,a1,8000029c <_start+0x29c>
    800001f6:	00053023          	sd	zero,0(a0)
    800001fa:	0521                	addi	a0,a0,8
    800001fc:	0ab57063          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000200:	00053023          	sd	zero,0(a0)
    80000204:	0521                	addi	a0,a0,8
    80000206:	08b57b63          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000020a:	00053023          	sd	zero,0(a0)
    8000020e:	0521                	addi	a0,a0,8
    80000210:	08b57663          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000214:	00053023          	sd	zero,0(a0)
    80000218:	0521                	addi	a0,a0,8
    8000021a:	08b57163          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000021e:	00053023          	sd	zero,0(a0)
    80000222:	0521                	addi	a0,a0,8
    80000224:	06b57c63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000228:	00053023          	sd	zero,0(a0)
    8000022c:	0521                	addi	a0,a0,8
    8000022e:	06b57763          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000232:	00053023          	sd	zero,0(a0)
    80000236:	0521                	addi	a0,a0,8
    80000238:	06b57263          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000023c:	00053023          	sd	zero,0(a0)
    80000240:	0521                	addi	a0,a0,8
    80000242:	04b57d63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000246:	00053023          	sd	zero,0(a0)
    8000024a:	0521                	addi	a0,a0,8
    8000024c:	04b57863          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000250:	00053023          	sd	zero,0(a0)
    80000254:	0521                	addi	a0,a0,8
    80000256:	04b57363          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000025a:	00053023          	sd	zero,0(a0)
    8000025e:	0521                	addi	a0,a0,8
    80000260:	02b57e63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000264:	00053023          	sd	zero,0(a0)
    80000268:	0521                	addi	a0,a0,8
    8000026a:	02b57963          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000026e:	00053023          	sd	zero,0(a0)
    80000272:	0521                	addi	a0,a0,8
    80000274:	02b57463          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000278:	00053023          	sd	zero,0(a0)
    8000027c:	0521                	addi	a0,a0,8
    8000027e:	00b57f63          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000282:	00053023          	sd	zero,0(a0)
    80000286:	0521                	addi	a0,a0,8
    80000288:	00b57a63          	bgeu	a0,a1,8000029c <_start+0x29c>
    8000028c:	00053023          	sd	zero,0(a0)
    80000290:	0521                	addi	a0,a0,8
    80000292:	00b57563          	bgeu	a0,a1,8000029c <_start+0x29c>
    80000296:	00053023          	sd	zero,0(a0)
    8000029a:	0521                	addi	a0,a0,8
    8000029c:	46e020ef          	jal	8000270a <main>
    800002a0:	000802b7          	lui	t0,0x80
    800002a4:	2285                	addiw	t0,t0,1 # 80001 <_start-0x7ff7ffff>
    800002a6:	02b2                	slli	t0,t0,0xc
    800002a8:	4305                	li	t1,1
    800002aa:	0062b023          	sd	t1,0(t0)
    800002ae:	a001                	j	800002ae <_start+0x2ae>

Disassembly of section .text:

0000000080002000 <portable_init>:
    80002000:	8082                	ret

0000000080002002 <portable_fini>:
    80002002:	8082                	ret

0000000080002004 <start_time>:
    80002004:	b00027f3          	csrr	a5,mcycle
    80002008:	00002717          	auipc	a4,0x2
    8000200c:	78f72823          	sw	a5,1936(a4) # 80004798 <t_start>
    80002010:	8082                	ret

0000000080002012 <stop_time>:
    80002012:	b00027f3          	csrr	a5,mcycle
    80002016:	00002717          	auipc	a4,0x2
    8000201a:	76f72f23          	sw	a5,1918(a4) # 80004794 <t_end>
    8000201e:	8082                	ret

0000000080002020 <get_time>:
    80002020:	00002517          	auipc	a0,0x2
    80002024:	77452503          	lw	a0,1908(a0) # 80004794 <t_end>
    80002028:	00002797          	auipc	a5,0x2
    8000202c:	7707a783          	lw	a5,1904(a5) # 80004798 <t_start>
    80002030:	9d1d                	subw	a0,a0,a5
    80002032:	8082                	ret

0000000080002034 <time_in_secs>:
    80002034:	8082                	ret

0000000080002036 <ee_printf>:
    80002036:	7139                	addi	sp,sp,-64
    80002038:	e42e                	sd	a1,8(sp)
    8000203a:	e832                	sd	a2,16(sp)
    8000203c:	ec36                	sd	a3,24(sp)
    8000203e:	f03a                	sd	a4,32(sp)
    80002040:	f43e                	sd	a5,40(sp)
    80002042:	f842                	sd	a6,48(sp)
    80002044:	fc46                	sd	a7,56(sp)
    80002046:	4501                	li	a0,0
    80002048:	6121                	addi	sp,sp,64
    8000204a:	8082                	ret

000000008000204c <gem5_roi_begin>:
    8000204c:	8082                	ret

000000008000204e <gem5_roi_end>:
    8000204e:	8082                	ret

0000000080002050 <gem5_bench_exit>:
    80002050:	8082                	ret

0000000080002052 <cmp_idx>:
    80002052:	c619                	beqz	a2,80002060 <cmp_idx+0xe>
    80002054:	00251503          	lh	a0,2(a0)
    80002058:	00259783          	lh	a5,2(a1)
    8000205c:	9d1d                	subw	a0,a0,a5
    8000205e:	8082                	ret
    80002060:	00051783          	lh	a5,0(a0)
    80002064:	0807c73b          	zext.h	a4,a5
    80002068:	0087571b          	srliw	a4,a4,0x8
    8000206c:	f007f793          	andi	a5,a5,-256
    80002070:	8fd9                	or	a5,a5,a4
    80002072:	00f51023          	sh	a5,0(a0)
    80002076:	00059783          	lh	a5,0(a1)
    8000207a:	00251503          	lh	a0,2(a0)
    8000207e:	0807c73b          	zext.h	a4,a5
    80002082:	0087571b          	srliw	a4,a4,0x8
    80002086:	f007f793          	andi	a5,a5,-256
    8000208a:	8fd9                	or	a5,a5,a4
    8000208c:	00f59023          	sh	a5,0(a1)
    80002090:	00259783          	lh	a5,2(a1)
    80002094:	9d1d                	subw	a0,a0,a5
    80002096:	8082                	ret

0000000080002098 <calc_func>:
    80002098:	00051803          	lh	a6,0(a0)
    8000209c:	48785793          	bexti	a5,a6,0x7
    800020a0:	c781                	beqz	a5,800020a8 <calc_func+0x10>
    800020a2:	07f87513          	andi	a0,a6,127
    800020a6:	8082                	ret
    800020a8:	03981713          	slli	a4,a6,0x39
    800020ac:	03c75793          	srli	a5,a4,0x3c
    800020b0:	7179                	addi	sp,sp,-48
    800020b2:	0047971b          	slliw	a4,a5,0x4
    800020b6:	00f70633          	add	a2,a4,a5
    800020ba:	f022                	sd	s0,32(sp)
    800020bc:	f406                	sd	ra,40(sp)
    800020be:	ec26                	sd	s1,24(sp)
    800020c0:	00787693          	andi	a3,a6,7
    800020c4:	0605d783          	lhu	a5,96(a1)
    800020c8:	88ae                	mv	a7,a1
    800020ca:	842a                	mv	s0,a0
    800020cc:	8732                	mv	a4,a2
    800020ce:	c2bd                	beqz	a3,80002134 <calc_func+0x9c>
    800020d0:	4605                	li	a2,1
    800020d2:	04c69d63          	bne	a3,a2,8000212c <calc_func+0x94>
    800020d6:	863e                	mv	a2,a5
    800020d8:	04088513          	addi	a0,a7,64
    800020dc:	85ba                	mv	a1,a4
    800020de:	e442                	sd	a6,8(sp)
    800020e0:	e046                	sd	a7,0(sp)
    800020e2:	156010ef          	jal	80003238 <core_bench_matrix>
    800020e6:	6882                	ld	a7,0(sp)
    800020e8:	6822                	ld	a6,8(sp)
    800020ea:	84aa                	mv	s1,a0
    800020ec:	0648d783          	lhu	a5,100(a7)
    800020f0:	efa5                	bnez	a5,80002168 <calc_func+0xd0>
    800020f2:	0608d783          	lhu	a5,96(a7)
    800020f6:	06a89223          	sh	a0,100(a7)
    800020fa:	85be                	mv	a1,a5
    800020fc:	e446                	sd	a7,8(sp)
    800020fe:	e042                	sd	a6,0(sp)
    80002100:	6e6010ef          	jal	800037e6 <crcu16>
    80002104:	6802                	ld	a6,0(sp)
    80002106:	68a2                	ld	a7,8(sp)
    80002108:	87aa                	mv	a5,a0
    8000210a:	f0087813          	andi	a6,a6,-256
    8000210e:	07f4f513          	andi	a0,s1,127
    80002112:	01056833          	or	a6,a0,a6
    80002116:	06f89023          	sh	a5,96(a7)
    8000211a:	08086813          	ori	a6,a6,128
    8000211e:	70a2                	ld	ra,40(sp)
    80002120:	01041023          	sh	a6,0(s0)
    80002124:	7402                	ld	s0,32(sp)
    80002126:	64e2                	ld	s1,24(sp)
    80002128:	6145                	addi	sp,sp,48
    8000212a:	8082                	ret
    8000212c:	0808453b          	zext.h	a0,a6
    80002130:	84c2                	mv	s1,a6
    80002132:	b7e1                	j	800020fa <calc_func+0x62>
    80002134:	02100693          	li	a3,33
    80002138:	00c6e463          	bltu	a3,a2,80002140 <calc_func+0xa8>
    8000213c:	02200713          	li	a4,34
    80002140:	00289683          	lh	a3,2(a7)
    80002144:	00089603          	lh	a2,0(a7)
    80002148:	0208b583          	ld	a1,32(a7)
    8000214c:	0288a503          	lw	a0,40(a7)
    80002150:	e442                	sd	a6,8(sp)
    80002152:	e046                	sd	a7,0(sp)
    80002154:	428010ef          	jal	8000357c <core_bench_state>
    80002158:	6882                	ld	a7,0(sp)
    8000215a:	6822                	ld	a6,8(sp)
    8000215c:	84aa                	mv	s1,a0
    8000215e:	0668d783          	lhu	a5,102(a7)
    80002162:	e399                	bnez	a5,80002168 <calc_func+0xd0>
    80002164:	06a89323          	sh	a0,102(a7)
    80002168:	0608d783          	lhu	a5,96(a7)
    8000216c:	b779                	j	800020fa <calc_func+0x62>

000000008000216e <cmp_complex>:
    8000216e:	7179                	addi	sp,sp,-48
    80002170:	ec26                	sd	s1,24(sp)
    80002172:	84ae                	mv	s1,a1
    80002174:	85b2                	mv	a1,a2
    80002176:	f406                	sd	ra,40(sp)
    80002178:	f022                	sd	s0,32(sp)
    8000217a:	e432                	sd	a2,8(sp)
    8000217c:	f1dff0ef          	jal	80002098 <calc_func>
    80002180:	65a2                	ld	a1,8(sp)
    80002182:	842a                	mv	s0,a0
    80002184:	8526                	mv	a0,s1
    80002186:	f13ff0ef          	jal	80002098 <calc_func>
    8000218a:	70a2                	ld	ra,40(sp)
    8000218c:	40a4053b          	subw	a0,s0,a0
    80002190:	7402                	ld	s0,32(sp)
    80002192:	64e2                	ld	s1,24(sp)
    80002194:	6145                	addi	sp,sp,48
    80002196:	8082                	ret

0000000080002198 <copy_info>:
    80002198:	00059703          	lh	a4,0(a1)
    8000219c:	00259783          	lh	a5,2(a1)
    800021a0:	00e51023          	sh	a4,0(a0)
    800021a4:	00f51123          	sh	a5,2(a0)
    800021a8:	8082                	ret

00000000800021aa <core_list_insert_new>:
    800021aa:	00063803          	ld	a6,0(a2)
    800021ae:	01080893          	addi	a7,a6,16
    800021b2:	02e8ff63          	bgeu	a7,a4,800021f0 <core_list_insert_new+0x46>
    800021b6:	6298                	ld	a4,0(a3)
    800021b8:	00470313          	addi	t1,a4,4
    800021bc:	02f37a63          	bgeu	t1,a5,800021f0 <core_list_insert_new+0x46>
    800021c0:	01163023          	sd	a7,0(a2)
    800021c4:	611c                	ld	a5,0(a0)
    800021c6:	00059883          	lh	a7,0(a1)
    800021ca:	00259603          	lh	a2,2(a1)
    800021ce:	00f83023          	sd	a5,0(a6)
    800021d2:	01053023          	sd	a6,0(a0)
    800021d6:	00e83423          	sd	a4,8(a6)
    800021da:	629c                	ld	a5,0(a3)
    800021dc:	8542                	mv	a0,a6
    800021de:	0791                	addi	a5,a5,4
    800021e0:	e29c                	sd	a5,0(a3)
    800021e2:	00883783          	ld	a5,8(a6)
    800021e6:	01179023          	sh	a7,0(a5)
    800021ea:	00c79123          	sh	a2,2(a5)
    800021ee:	8082                	ret
    800021f0:	4801                	li	a6,0
    800021f2:	8542                	mv	a0,a6
    800021f4:	8082                	ret

00000000800021f6 <core_list_remove>:
    800021f6:	87aa                	mv	a5,a0
    800021f8:	6108                	ld	a0,0(a0)
    800021fa:	6794                	ld	a3,8(a5)
    800021fc:	6510                	ld	a2,8(a0)
    800021fe:	6118                	ld	a4,0(a0)
    80002200:	e790                	sd	a2,8(a5)
    80002202:	e514                	sd	a3,8(a0)
    80002204:	e398                	sd	a4,0(a5)
    80002206:	00053023          	sd	zero,0(a0)
    8000220a:	8082                	ret

000000008000220c <core_list_undo_remove>:
    8000220c:	6594                	ld	a3,8(a1)
    8000220e:	6518                	ld	a4,8(a0)
    80002210:	619c                	ld	a5,0(a1)
    80002212:	e514                	sd	a3,8(a0)
    80002214:	e598                	sd	a4,8(a1)
    80002216:	e11c                	sd	a5,0(a0)
    80002218:	e188                	sd	a0,0(a1)
    8000221a:	8082                	ret

000000008000221c <core_list_find>:
    8000221c:	00259703          	lh	a4,2(a1)
    80002220:	00074c63          	bltz	a4,80002238 <core_list_find+0x1c>
    80002224:	e501                	bnez	a0,8000222c <core_list_find+0x10>
    80002226:	8082                	ret
    80002228:	6108                	ld	a0,0(a0)
    8000222a:	c115                	beqz	a0,8000224e <core_list_find+0x32>
    8000222c:	651c                	ld	a5,8(a0)
    8000222e:	00279783          	lh	a5,2(a5)
    80002232:	fee79be3          	bne	a5,a4,80002228 <core_list_find+0xc>
    80002236:	8082                	ret
    80002238:	c919                	beqz	a0,8000224e <core_list_find+0x32>
    8000223a:	00059703          	lh	a4,0(a1)
    8000223e:	a019                	j	80002244 <core_list_find+0x28>
    80002240:	6108                	ld	a0,0(a0)
    80002242:	c511                	beqz	a0,8000224e <core_list_find+0x32>
    80002244:	651c                	ld	a5,8(a0)
    80002246:	0007c783          	lbu	a5,0(a5)
    8000224a:	fee79be3          	bne	a5,a4,80002240 <core_list_find+0x24>
    8000224e:	8082                	ret

0000000080002250 <core_list_reverse>:
    80002250:	c901                	beqz	a0,80002260 <core_list_reverse+0x10>
    80002252:	4701                	li	a4,0
    80002254:	a011                	j	80002258 <core_list_reverse+0x8>
    80002256:	853e                	mv	a0,a5
    80002258:	611c                	ld	a5,0(a0)
    8000225a:	e118                	sd	a4,0(a0)
    8000225c:	872a                	mv	a4,a0
    8000225e:	ffe5                	bnez	a5,80002256 <core_list_reverse+0x6>
    80002260:	8082                	ret

0000000080002262 <core_list_mergesort>:
    80002262:	711d                	addi	sp,sp,-96
    80002264:	e0ca                	sd	s2,64(sp)
    80002266:	f456                	sd	s5,40(sp)
    80002268:	f05a                	sd	s6,32(sp)
    8000226a:	ec5e                	sd	s7,24(sp)
    8000226c:	e06a                	sd	s10,0(sp)
    8000226e:	4a85                	li	s5,1
    80002270:	ec86                	sd	ra,88(sp)
    80002272:	e8a2                	sd	s0,80(sp)
    80002274:	e4a6                	sd	s1,72(sp)
    80002276:	fc4e                	sd	s3,56(sp)
    80002278:	f852                	sd	s4,48(sp)
    8000227a:	e862                	sd	s8,16(sp)
    8000227c:	e466                	sd	s9,8(sp)
    8000227e:	892a                	mv	s2,a0
    80002280:	8bae                	mv	s7,a1
    80002282:	8b32                	mv	s6,a2
    80002284:	8d56                	mv	s10,s5
    80002286:	0a090263          	beqz	s2,8000232a <core_list_mergesort+0xc8>
    8000228a:	4c81                	li	s9,0
    8000228c:	4481                	li	s1,0
    8000228e:	4c01                	li	s8,0
    80002290:	2c85                	addiw	s9,s9,1
    80002292:	87ca                	mv	a5,s2
    80002294:	4401                	li	s0,0
    80002296:	01545563          	bge	s0,s5,800022a0 <core_list_mergesort+0x3e>
    8000229a:	639c                	ld	a5,0(a5)
    8000229c:	2405                	addiw	s0,s0,1
    8000229e:	ffe5                	bnez	a5,80002296 <core_list_mergesort+0x34>
    800022a0:	89ca                	mv	s3,s2
    800022a2:	8a56                	mv	s4,s5
    800022a4:	893e                	mv	s2,a5
    800022a6:	00805f63          	blez	s0,800022c4 <core_list_mergesort+0x62>
    800022aa:	000a0463          	beqz	s4,800022b2 <core_list_mergesort+0x50>
    800022ae:	02091163          	bnez	s2,800022d0 <core_list_mergesort+0x6e>
    800022b2:	87a6                	mv	a5,s1
    800022b4:	347d                	addiw	s0,s0,-1
    800022b6:	84ce                	mv	s1,s3
    800022b8:	0009b983          	ld	s3,0(s3)
    800022bc:	cb85                	beqz	a5,800022ec <core_list_mergesort+0x8a>
    800022be:	e384                	sd	s1,0(a5)
    800022c0:	fe8045e3          	bgtz	s0,800022aa <core_list_mergesort+0x48>
    800022c4:	012037b3          	snez	a5,s2
    800022c8:	05405763          	blez	s4,80002316 <core_list_mergesort+0xb4>
    800022cc:	c7b1                	beqz	a5,80002318 <core_list_mergesort+0xb6>
    800022ce:	c805                	beqz	s0,800022fe <core_list_mergesort+0x9c>
    800022d0:	00893583          	ld	a1,8(s2)
    800022d4:	0089b503          	ld	a0,8(s3)
    800022d8:	865a                	mv	a2,s6
    800022da:	9b82                	jalr	s7
    800022dc:	04a05a63          	blez	a0,80002330 <core_list_mergesort+0xce>
    800022e0:	87a6                	mv	a5,s1
    800022e2:	3a7d                	addiw	s4,s4,-1
    800022e4:	84ca                	mv	s1,s2
    800022e6:	00093903          	ld	s2,0(s2)
    800022ea:	fbf1                	bnez	a5,800022be <core_list_mergesort+0x5c>
    800022ec:	8c26                	mv	s8,s1
    800022ee:	bf65                	j	800022a6 <core_list_mergesort+0x44>
    800022f0:	e098                	sd	a4,0(s1)
    800022f2:	012037b3          	snez	a5,s2
    800022f6:	84ba                	mv	s1,a4
    800022f8:	000a0e63          	beqz	s4,80002314 <core_list_mergesort+0xb2>
    800022fc:	cf81                	beqz	a5,80002314 <core_list_mergesort+0xb2>
    800022fe:	874a                	mv	a4,s2
    80002300:	3a7d                	addiw	s4,s4,-1
    80002302:	00093903          	ld	s2,0(s2)
    80002306:	f4ed                	bnez	s1,800022f0 <core_list_mergesort+0x8e>
    80002308:	8c3a                	mv	s8,a4
    8000230a:	012037b3          	snez	a5,s2
    8000230e:	84ba                	mv	s1,a4
    80002310:	fe0a16e3          	bnez	s4,800022fc <core_list_mergesort+0x9a>
    80002314:	84ba                	mv	s1,a4
    80002316:	ffad                	bnez	a5,80002290 <core_list_mergesort+0x2e>
    80002318:	0004b023          	sd	zero,0(s1)
    8000231c:	03ac8963          	beq	s9,s10,8000234e <core_list_mergesort+0xec>
    80002320:	8962                	mv	s2,s8
    80002322:	001a9a9b          	slliw	s5,s5,0x1
    80002326:	f60912e3          	bnez	s2,8000228a <core_list_mergesort+0x28>
    8000232a:	00003023          	sd	zero,0(zero) # 0 <_start-0x80000000>
    8000232e:	9002                	ebreak
    80002330:	0009b703          	ld	a4,0(s3)
    80002334:	347d                	addiw	s0,s0,-1
    80002336:	c491                	beqz	s1,80002342 <core_list_mergesort+0xe0>
    80002338:	87a6                	mv	a5,s1
    8000233a:	84ce                	mv	s1,s3
    8000233c:	e384                	sd	s1,0(a5)
    8000233e:	89ba                	mv	s3,a4
    80002340:	b741                	j	800022c0 <core_list_mergesort+0x5e>
    80002342:	8c4e                	mv	s8,s3
    80002344:	84ce                	mv	s1,s3
    80002346:	89ba                	mv	s3,a4
    80002348:	f88044e3          	bgtz	s0,800022d0 <core_list_mergesort+0x6e>
    8000234c:	bfa5                	j	800022c4 <core_list_mergesort+0x62>
    8000234e:	60e6                	ld	ra,88(sp)
    80002350:	6446                	ld	s0,80(sp)
    80002352:	64a6                	ld	s1,72(sp)
    80002354:	6906                	ld	s2,64(sp)
    80002356:	79e2                	ld	s3,56(sp)
    80002358:	7a42                	ld	s4,48(sp)
    8000235a:	7aa2                	ld	s5,40(sp)
    8000235c:	7b02                	ld	s6,32(sp)
    8000235e:	6be2                	ld	s7,24(sp)
    80002360:	6ca2                	ld	s9,8(sp)
    80002362:	6d02                	ld	s10,0(sp)
    80002364:	8562                	mv	a0,s8
    80002366:	6c42                	ld	s8,16(sp)
    80002368:	6125                	addi	sp,sp,96
    8000236a:	8082                	ret

000000008000236c <core_bench_list>:
    8000236c:	00451e83          	lh	t4,4(a0)
    80002370:	7139                	addi	sp,sp,-64
    80002372:	f822                	sd	s0,48(sp)
    80002374:	fc06                	sd	ra,56(sp)
    80002376:	f426                	sd	s1,40(sp)
    80002378:	f04a                	sd	s2,32(sp)
    8000237a:	ec4e                	sd	s3,24(sp)
    8000237c:	7d00                	ld	s0,56(a0)
    8000237e:	1fd05463          	blez	t4,80002566 <core_bench_list+0x1fa>
    80002382:	1e05c663          	bltz	a1,8000256e <core_bench_list+0x202>
    80002386:	1e040d63          	beqz	s0,80002580 <core_bench_list+0x214>
    8000238a:	86ae                	mv	a3,a1
    8000238c:	4e01                	li	t3,0
    8000238e:	4f01                	li	t5,0
    80002390:	4481                	li	s1,0
    80002392:	4601                	li	a2,0
    80002394:	4301                	li	t1,0
    80002396:	87a2                	mv	a5,s0
    80002398:	a019                	j	8000239e <core_bench_list+0x32>
    8000239a:	639c                	ld	a5,0(a5)
    8000239c:	c3c5                	beqz	a5,8000243c <core_bench_list+0xd0>
    8000239e:	6798                	ld	a4,8(a5)
    800023a0:	00271803          	lh	a6,2(a4)
    800023a4:	fed81be3          	bne	a6,a3,8000239a <core_bench_list+0x2e>
    800023a8:	4681                	li	a3,0
    800023aa:	a011                	j	800023ae <core_bench_list+0x42>
    800023ac:	843a                	mv	s0,a4
    800023ae:	6018                	ld	a4,0(s0)
    800023b0:	e014                	sd	a3,0(s0)
    800023b2:	86a2                	mv	a3,s0
    800023b4:	ff65                	bnez	a4,800023ac <core_bench_list+0x40>
    800023b6:	c7c9                	beqz	a5,80002440 <core_bench_list+0xd4>
    800023b8:	6798                	ld	a4,8(a5)
    800023ba:	0007b883          	ld	a7,0(a5)
    800023be:	2485                	addiw	s1,s1,1
    800023c0:	00071683          	lh	a3,0(a4)
    800023c4:	4896d713          	bexti	a4,a3,0x9
    800023c8:	9f31                	addw	a4,a4,a2
    800023ca:	8a85                	andi	a3,a3,1
    800023cc:	0807473b          	zext.h	a4,a4
    800023d0:	0ed75733          	czero.eqz	a4,a4,a3
    800023d4:	0ed676b3          	czero.nez	a3,a2,a3
    800023d8:	00e68633          	add	a2,a3,a4
    800023dc:	00088a63          	beqz	a7,800023f0 <core_bench_list+0x84>
    800023e0:	0008b703          	ld	a4,0(a7)
    800023e4:	e398                	sd	a4,0(a5)
    800023e6:	601c                	ld	a5,0(s0)
    800023e8:	00f8b023          	sd	a5,0(a7)
    800023ec:	01143023          	sd	a7,0(s0)
    800023f0:	02084463          	bltz	a6,80002418 <core_bench_list+0xac>
    800023f4:	001e079b          	addiw	a5,t3,1
    800023f8:	0018069b          	addiw	a3,a6,1
    800023fc:	60579e13          	sext.h	t3,a5
    80002400:	60569693          	sext.h	a3,a3
    80002404:	05ce8c63          	beq	t4,t3,8000245c <core_bench_list+0xf0>
    80002408:	0ff7f313          	zext.b	t1,a5
    8000240c:	f806d5e3          	bgez	a3,80002396 <core_bench_list+0x2a>
    80002410:	869a                	mv	a3,t1
    80002412:	87a2                	mv	a5,s0
    80002414:	7861                	lui	a6,0xffff8
    80002416:	a829                	j	80002430 <core_bench_list+0xc4>
    80002418:	001e069b          	addiw	a3,t3,1
    8000241c:	60569e13          	sext.h	t3,a3
    80002420:	03ce8d63          	beq	t4,t3,8000245a <core_bench_list+0xee>
    80002424:	0ff6f693          	zext.b	a3,a3
    80002428:	87a2                	mv	a5,s0
    8000242a:	a019                	j	80002430 <core_bench_list+0xc4>
    8000242c:	639c                	ld	a5,0(a5)
    8000242e:	c785                	beqz	a5,80002456 <core_bench_list+0xea>
    80002430:	6798                	ld	a4,8(a5)
    80002432:	00074303          	lbu	t1,0(a4)
    80002436:	fed31be3          	bne	t1,a3,8000242c <core_bench_list+0xc0>
    8000243a:	b7bd                	j	800023a8 <core_bench_list+0x3c>
    8000243c:	8836                	mv	a6,a3
    8000243e:	b7ad                	j	800023a8 <core_bench_list+0x3c>
    80002440:	601c                	ld	a5,0(s0)
    80002442:	2f05                	addiw	t5,t5,1
    80002444:	679c                	ld	a5,8(a5)
    80002446:	00079783          	lh	a5,0(a5)
    8000244a:	4887d793          	bexti	a5,a5,0x8
    8000244e:	9fb1                	addw	a5,a5,a2
    80002450:	0807c63b          	zext.h	a2,a5
    80002454:	bf71                	j	800023f0 <core_bench_list+0x84>
    80002456:	8336                	mv	t1,a3
    80002458:	bf81                	j	800023a8 <core_bench_list+0x3c>
    8000245a:	86c2                	mv	a3,a6
    8000245c:	0024949b          	slliw	s1,s1,0x2
    80002460:	41e484bb          	subw	s1,s1,t5
    80002464:	9cb1                	addw	s1,s1,a2
    80002466:	0804c4bb          	zext.h	s1,s1
    8000246a:	00b05f63          	blez	a1,80002488 <core_bench_list+0x11c>
    8000246e:	862a                	mv	a2,a0
    80002470:	00000597          	auipc	a1,0x0
    80002474:	cfe58593          	addi	a1,a1,-770 # 8000216e <cmp_complex>
    80002478:	8522                	mv	a0,s0
    8000247a:	e41a                	sd	t1,8(sp)
    8000247c:	e036                	sd	a3,0(sp)
    8000247e:	de5ff0ef          	jal	80002262 <core_list_mergesort>
    80002482:	6322                	ld	t1,8(sp)
    80002484:	6682                	ld	a3,0(sp)
    80002486:	842a                	mv	s0,a0
    80002488:	601c                	ld	a5,0(s0)
    8000248a:	8922                	mv	s2,s0
    8000248c:	0007b983          	ld	s3,0(a5)
    80002490:	6798                	ld	a4,8(a5)
    80002492:	0089b583          	ld	a1,8(s3)
    80002496:	0009b603          	ld	a2,0(s3)
    8000249a:	e78c                	sd	a1,8(a5)
    8000249c:	00e9b423          	sd	a4,8(s3)
    800024a0:	e390                	sd	a2,0(a5)
    800024a2:	0009b023          	sd	zero,0(s3)
    800024a6:	0006d763          	bgez	a3,800024b4 <core_bench_list+0x148>
    800024aa:	a079                	j	80002538 <core_bench_list+0x1cc>
    800024ac:	00093903          	ld	s2,0(s2)
    800024b0:	08090b63          	beqz	s2,80002546 <core_bench_list+0x1da>
    800024b4:	00893783          	ld	a5,8(s2)
    800024b8:	00279783          	lh	a5,2(a5)
    800024bc:	fed798e3          	bne	a5,a3,800024ac <core_bench_list+0x140>
    800024c0:	641c                	ld	a5,8(s0)
    800024c2:	85a6                	mv	a1,s1
    800024c4:	00079503          	lh	a0,0(a5)
    800024c8:	0c9010ef          	jal	80003d90 <crc16>
    800024cc:	00093903          	ld	s2,0(s2)
    800024d0:	84aa                	mv	s1,a0
    800024d2:	fe0917e3          	bnez	s2,800024c0 <core_bench_list+0x154>
    800024d6:	00043903          	ld	s2,0(s0)
    800024da:	0089b703          	ld	a4,8(s3)
    800024de:	00893683          	ld	a3,8(s2)
    800024e2:	00093783          	ld	a5,0(s2)
    800024e6:	8522                	mv	a0,s0
    800024e8:	00d9b423          	sd	a3,8(s3)
    800024ec:	00e93423          	sd	a4,8(s2)
    800024f0:	00f9b023          	sd	a5,0(s3)
    800024f4:	01393023          	sd	s3,0(s2)
    800024f8:	4601                	li	a2,0
    800024fa:	00000597          	auipc	a1,0x0
    800024fe:	b5858593          	addi	a1,a1,-1192 # 80002052 <cmp_idx>
    80002502:	d61ff0ef          	jal	80002262 <core_list_mergesort>
    80002506:	6100                	ld	s0,0(a0)
    80002508:	892a                	mv	s2,a0
    8000250a:	c819                	beqz	s0,80002520 <core_bench_list+0x1b4>
    8000250c:	00893783          	ld	a5,8(s2)
    80002510:	85a6                	mv	a1,s1
    80002512:	00079503          	lh	a0,0(a5)
    80002516:	07b010ef          	jal	80003d90 <crc16>
    8000251a:	6000                	ld	s0,0(s0)
    8000251c:	84aa                	mv	s1,a0
    8000251e:	f47d                	bnez	s0,8000250c <core_bench_list+0x1a0>
    80002520:	70e2                	ld	ra,56(sp)
    80002522:	7442                	ld	s0,48(sp)
    80002524:	7902                	ld	s2,32(sp)
    80002526:	69e2                	ld	s3,24(sp)
    80002528:	8526                	mv	a0,s1
    8000252a:	74a2                	ld	s1,40(sp)
    8000252c:	6121                	addi	sp,sp,64
    8000252e:	8082                	ret
    80002530:	00093903          	ld	s2,0(s2)
    80002534:	00090963          	beqz	s2,80002546 <core_bench_list+0x1da>
    80002538:	00893783          	ld	a5,8(s2)
    8000253c:	0007c783          	lbu	a5,0(a5)
    80002540:	fef318e3          	bne	t1,a5,80002530 <core_bench_list+0x1c4>
    80002544:	bfb5                	j	800024c0 <core_bench_list+0x154>
    80002546:	00043903          	ld	s2,0(s0)
    8000254a:	f8090ae3          	beqz	s2,800024de <core_bench_list+0x172>
    8000254e:	641c                	ld	a5,8(s0)
    80002550:	85a6                	mv	a1,s1
    80002552:	00079503          	lh	a0,0(a5)
    80002556:	03b010ef          	jal	80003d90 <crc16>
    8000255a:	00093903          	ld	s2,0(s2)
    8000255e:	84aa                	mv	s1,a0
    80002560:	f60910e3          	bnez	s2,800024c0 <core_bench_list+0x154>
    80002564:	bf8d                	j	800024d6 <core_bench_list+0x16a>
    80002566:	86ae                	mv	a3,a1
    80002568:	4481                	li	s1,0
    8000256a:	4301                	li	t1,0
    8000256c:	bdfd                	j	8000246a <core_bench_list+0xfe>
    8000256e:	c809                	beqz	s0,80002580 <core_bench_list+0x214>
    80002570:	882e                	mv	a6,a1
    80002572:	87a2                	mv	a5,s0
    80002574:	4601                	li	a2,0
    80002576:	4681                	li	a3,0
    80002578:	4f01                	li	t5,0
    8000257a:	4e01                	li	t3,0
    8000257c:	4481                	li	s1,0
    8000257e:	bd4d                	j	80002430 <core_bench_list+0xc4>
    80002580:	00003783          	ld	a5,0(zero) # 0 <_start-0x80000000>
    80002584:	9002                	ebreak

0000000080002586 <core_list_init>:
    80002586:	4cccd7b7          	lui	a5,0x4cccd
    8000258a:	29f79793          	bseti	a5,a5,0x1f
    8000258e:	08050e3b          	zext.w	t3,a0
    80002592:	ccd78793          	addi	a5,a5,-819 # 4ccccccd <_start-0x33333333>
    80002596:	02fe0e33          	mul	t3,t3,a5
    8000259a:	77e1                	lui	a5,0xffff8
    8000259c:	0005b023          	sd	zero,0(a1)
    800025a0:	08078793          	addi	a5,a5,128 # ffffffffffff8080 <__bss_end+0xffffffff7fff38d0>
    800025a4:	02058693          	addi	a3,a1,32
    800025a8:	01058513          	addi	a0,a1,16
    800025ac:	7761                	lui	a4,0xffff8
    800025ae:	024e5e13          	srli	t3,t3,0x24
    800025b2:	3e79                	addiw	t3,t3,-2
    800025b4:	084e1e9b          	slli.uw	t4,t3,0x4
    800025b8:	9eae                	add	t4,t4,a1
    800025ba:	01d5b423          	sd	t4,8(a1)
    800025be:	00fe9023          	sh	a5,0(t4)
    800025c2:	000e9123          	sh	zero,2(t4)
    800025c6:	21de4fbb          	sh2add.uw	t6,t3,t4
    800025ca:	004e8793          	addi	a5,t4,4
    800025ce:	080e02bb          	zext.w	t0,t3
    800025d2:	0dd6fb63          	bgeu	a3,t4,800026a8 <core_list_init+0x122>
    800025d6:	008e8813          	addi	a6,t4,8
    800025da:	0df87763          	bgeu	a6,t6,800026a8 <core_list_init+0x122>
    800025de:	ed9c                	sd	a5,24(a1)
    800025e0:	0005b823          	sd	zero,16(a1)
    800025e4:	e188                	sd	a0,0(a1)
    800025e6:	fff74713          	not	a4,a4
    800025ea:	57fd                	li	a5,-1
    800025ec:	00ee9323          	sh	a4,6(t4)
    800025f0:	00fe9223          	sh	a5,4(t4)
    800025f4:	7f61                	lui	t5,0xffff8
    800025f6:	ffff4f13          	not	t5,t5
    800025fa:	4701                	li	a4,0
    800025fc:	040e0563          	beqz	t3,80002646 <core_list_init+0xc0>
    80002600:	00c747b3          	xor	a5,a4,a2
    80002604:	0037979b          	slliw	a5,a5,0x3
    80002608:	00777513          	andi	a0,a4,7
    8000260c:	0787f793          	andi	a5,a5,120
    80002610:	8fc9                	or	a5,a5,a0
    80002612:	0087989b          	slliw	a7,a5,0x8
    80002616:	01068313          	addi	t1,a3,16
    8000261a:	2705                	addiw	a4,a4,1 # ffffffffffff8001 <__bss_end+0xffffffff7fff3851>
    8000261c:	00480513          	addi	a0,a6,4 # ffffffffffff8004 <__bss_end+0xffffffff7fff3854>
    80002620:	00f888bb          	addw	a7,a7,a5
    80002624:	01d37f63          	bgeu	t1,t4,80002642 <core_list_init+0xbc>
    80002628:	01f57d63          	bgeu	a0,t6,80002642 <core_list_init+0xbc>
    8000262c:	619c                	ld	a5,0(a1)
    8000262e:	e29c                	sd	a5,0(a3)
    80002630:	e194                	sd	a3,0(a1)
    80002632:	0106b423          	sd	a6,8(a3)
    80002636:	01181023          	sh	a7,0(a6)
    8000263a:	01e81123          	sh	t5,2(a6)
    8000263e:	869a                	mv	a3,t1
    80002640:	882a                	mv	a6,a0
    80002642:	faee1fe3          	bne	t3,a4,80002600 <core_list_init+0x7a>
    80002646:	6188                	ld	a0,0(a1)
    80002648:	6114                	ld	a3,0(a0)
    8000264a:	caa1                	beqz	a3,8000269a <core_list_init+0x114>
    8000264c:	4cccd7b7          	lui	a5,0x4cccd
    80002650:	29f79793          	bseti	a5,a5,0x1f
    80002654:	ccd78793          	addi	a5,a5,-819 # 4ccccccd <_start-0x33333333>
    80002658:	02f28333          	mul	t1,t0,a5
    8000265c:	6e11                	lui	t3,0x4
    8000265e:	1e7d                	addi	t3,t3,-1 # 3fff <_start-0x7fffc001>
    80002660:	20000813          	li	a6,512
    80002664:	4705                	li	a4,1
    80002666:	02235313          	srli	t1,t1,0x22
    8000266a:	a011                	j	8000266e <core_list_init+0xe8>
    8000266c:	86c6                	mv	a3,a7
    8000266e:	70087793          	andi	a5,a6,1792
    80002672:	00c748b3          	xor	a7,a4,a2
    80002676:	0117e7b3          	or	a5,a5,a7
    8000267a:	6508                	ld	a0,8(a0)
    8000267c:	01c7f7b3          	and	a5,a5,t3
    80002680:	00677363          	bgeu	a4,t1,80002686 <core_list_init+0x100>
    80002684:	87ba                	mv	a5,a4
    80002686:	0006b883          	ld	a7,0(a3)
    8000268a:	00f51123          	sh	a5,2(a0)
    8000268e:	2705                	addiw	a4,a4,1
    80002690:	1008081b          	addiw	a6,a6,256
    80002694:	8536                	mv	a0,a3
    80002696:	fc089be3          	bnez	a7,8000266c <core_list_init+0xe6>
    8000269a:	852e                	mv	a0,a1
    8000269c:	4601                	li	a2,0
    8000269e:	00000597          	auipc	a1,0x0
    800026a2:	9b458593          	addi	a1,a1,-1612 # 80002052 <cmp_idx>
    800026a6:	be75                	j	80002262 <core_list_mergesort>
    800026a8:	883e                	mv	a6,a5
    800026aa:	86aa                	mv	a3,a0
    800026ac:	b7a1                	j	800025f4 <core_list_init+0x6e>

00000000800026ae <iterate>:
    800026ae:	1101                	addi	sp,sp,-32
    800026b0:	e04a                	sd	s2,0(sp)
    800026b2:	02c52903          	lw	s2,44(a0)
    800026b6:	ec06                	sd	ra,24(sp)
    800026b8:	06053023          	sd	zero,96(a0)
    800026bc:	04090263          	beqz	s2,80002700 <iterate+0x52>
    800026c0:	e822                	sd	s0,16(sp)
    800026c2:	e426                	sd	s1,8(sp)
    800026c4:	842a                	mv	s0,a0
    800026c6:	4481                	li	s1,0
    800026c8:	4585                	li	a1,1
    800026ca:	8522                	mv	a0,s0
    800026cc:	ca1ff0ef          	jal	8000236c <core_bench_list>
    800026d0:	06045583          	lhu	a1,96(s0)
    800026d4:	112010ef          	jal	800037e6 <crcu16>
    800026d8:	06a41023          	sh	a0,96(s0)
    800026dc:	55fd                	li	a1,-1
    800026de:	8522                	mv	a0,s0
    800026e0:	c8dff0ef          	jal	8000236c <core_bench_list>
    800026e4:	06045583          	lhu	a1,96(s0)
    800026e8:	0fe010ef          	jal	800037e6 <crcu16>
    800026ec:	06a41023          	sh	a0,96(s0)
    800026f0:	e099                	bnez	s1,800026f6 <iterate+0x48>
    800026f2:	06a41123          	sh	a0,98(s0)
    800026f6:	2485                	addiw	s1,s1,1
    800026f8:	fc9918e3          	bne	s2,s1,800026c8 <iterate+0x1a>
    800026fc:	6442                	ld	s0,16(sp)
    800026fe:	64a2                	ld	s1,8(sp)
    80002700:	60e2                	ld	ra,24(sp)
    80002702:	6902                	ld	s2,0(sp)
    80002704:	4501                	li	a0,0
    80002706:	6105                	addi	sp,sp,32
    80002708:	8082                	ret

000000008000270a <main>:
    8000270a:	7131                	addi	sp,sp,-192
    8000270c:	fd06                	sd	ra,184(sp)
    8000270e:	f922                	sd	s0,176(sp)
    80002710:	f526                	sd	s1,168(sp)
    80002712:	f14a                	sd	s2,160(sp)
    80002714:	ed4e                	sd	s3,152(sp)
    80002716:	e952                	sd	s4,144(sp)
    80002718:	e556                	sd	s5,136(sp)
    8000271a:	e15a                	sd	s6,128(sp)
    8000271c:	fcde                	sd	s7,120(sp)
    8000271e:	f8e2                	sd	s8,112(sp)
    80002720:	f4e6                	sd	s9,104(sp)
    80002722:	f0ea                	sd	s10,96(sp)
    80002724:	81010113          	addi	sp,sp,-2032
    80002728:	0880                	addi	s0,sp,80
    8000272a:	fb840613          	addi	a2,s0,-72
    8000272e:	fb440593          	addi	a1,s0,-76
    80002732:	07a10513          	addi	a0,sp,122
    80002736:	c202                	sw	zero,4(sp)
    80002738:	8c9ff0ef          	jal	80002000 <portable_init>
    8000273c:	4505                	li	a0,1
    8000273e:	759000ef          	jal	80003696 <get_seed_32>
    80002742:	00a11823          	sh	a0,16(sp)
    80002746:	4509                	li	a0,2
    80002748:	74f000ef          	jal	80003696 <get_seed_32>
    8000274c:	00a11923          	sh	a0,18(sp)
    80002750:	450d                	li	a0,3
    80002752:	745000ef          	jal	80003696 <get_seed_32>
    80002756:	00a11a23          	sh	a0,20(sp)
    8000275a:	4511                	li	a0,4
    8000275c:	73b000ef          	jal	80003696 <get_seed_32>
    80002760:	de2a                	sw	a0,60(sp)
    80002762:	4515                	li	a0,5
    80002764:	733000ef          	jal	80003696 <get_seed_32>
    80002768:	ff950713          	addi	a4,a0,-7
    8000276c:	67c2                	ld	a5,16(sp)
    8000276e:	0ea75533          	czero.eqz	a0,a4,a0
    80002772:	051d                	addi	a0,a0,7
    80002774:	07c2                	slli	a5,a5,0x10
    80002776:	c0aa                	sw	a0,64(sp)
    80002778:	85010413          	addi	s0,sp,-1968
    8000277c:	56078a63          	beqz	a5,80002cf0 <main+0x5e6>
    80002780:	0107d713          	srli	a4,a5,0x10
    80002784:	4785                	li	a5,1
    80002786:	56f70e63          	beq	a4,a5,80002d02 <main+0x5f8>
    8000278a:	00157793          	andi	a5,a0,1
    8000278e:	00257693          	andi	a3,a0,2
    80002792:	00178713          	addi	a4,a5,1
    80002796:	0ed75733          	czero.eqz	a4,a4,a3
    8000279a:	0ed7f7b3          	czero.nez	a5,a5,a3
    8000279e:	97ba                	add	a5,a5,a4
    800027a0:	00457693          	andi	a3,a0,4
    800027a4:	00178713          	addi	a4,a5,1
    800027a8:	0ed75733          	czero.eqz	a4,a4,a3
    800027ac:	0ed7f7b3          	czero.nez	a5,a5,a3
    800027b0:	97ba                	add	a5,a5,a4
    800027b2:	7d000593          	li	a1,2000
    800027b6:	02f5d5bb          	divuw	a1,a1,a5
    800027ba:	0804                	addi	s1,sp,16
    800027bc:	08010313          	addi	t1,sp,128
    800027c0:	06011c23          	sh	zero,120(sp)
    800027c4:	86a6                	mv	a3,s1
    800027c6:	7c643423          	sd	t1,1992(s0)
    800027ca:	4701                	li	a4,0
    800027cc:	4601                	li	a2,0
    800027ce:	4885                	li	a7,1
    800027d0:	480d                	li	a6,3
    800027d2:	7eb42423          	sw	a1,2024(s0)
    800027d6:	00e897bb          	sllw	a5,a7,a4
    800027da:	8fe9                	and	a5,a5,a0
    800027dc:	2781                	sext.w	a5,a5
    800027de:	2705                	addiw	a4,a4,1
    800027e0:	12079863          	bnez	a5,80002910 <main+0x206>
    800027e4:	06a1                	addi	a3,a3,8
    800027e6:	ff0718e3          	bne	a4,a6,800027d6 <main+0xcc>
    800027ea:	7f042783          	lw	a5,2032(s0)
    800027ee:	0017f713          	andi	a4,a5,1
    800027f2:	cf09                	beqz	a4,8000280c <main+0x102>
    800027f4:	7c041603          	lh	a2,1984(s0)
    800027f8:	7d043583          	ld	a1,2000(s0)
    800027fc:	7e842503          	lw	a0,2024(s0)
    80002800:	d87ff0ef          	jal	80002586 <core_list_init>
    80002804:	7f042783          	lw	a5,2032(s0)
    80002808:	7ea43c23          	sd	a0,2040(s0)
    8000280c:	0027f713          	andi	a4,a5,2
    80002810:	0c071e63          	bnez	a4,800028ec <main+0x1e2>
    80002814:	8b91                	andi	a5,a5,4
    80002816:	cb89                	beqz	a5,80002828 <main+0x11e>
    80002818:	7e043603          	ld	a2,2016(s0)
    8000281c:	7c041583          	lh	a1,1984(s0)
    80002820:	7e842503          	lw	a0,2024(s0)
    80002824:	237000ef          	jal	8000325a <core_init_state>
    80002828:	7ec42783          	lw	a5,2028(s0)
    8000282c:	e3b9                	bnez	a5,80002872 <main+0x168>
    8000282e:	4785                	li	a5,1
    80002830:	7ef42623          	sw	a5,2028(s0)
    80002834:	7ec42703          	lw	a4,2028(s0)
    80002838:	0027179b          	slliw	a5,a4,0x2
    8000283c:	9fb9                	addw	a5,a5,a4
    8000283e:	0017979b          	slliw	a5,a5,0x1
    80002842:	7ef42623          	sw	a5,2028(s0)
    80002846:	fbeff0ef          	jal	80002004 <start_time>
    8000284a:	8526                	mv	a0,s1
    8000284c:	e63ff0ef          	jal	800026ae <iterate>
    80002850:	fc2ff0ef          	jal	80002012 <stop_time>
    80002854:	fccff0ef          	jal	80002020 <get_time>
    80002858:	fdcff0ef          	jal	80002034 <time_in_secs>
    8000285c:	dd61                	beqz	a0,80002834 <main+0x12a>
    8000285e:	47a9                	li	a5,10
    80002860:	02a7d7bb          	divuw	a5,a5,a0
    80002864:	7ec42703          	lw	a4,2028(s0)
    80002868:	2785                	addiw	a5,a5,1
    8000286a:	02f707bb          	mulw	a5,a4,a5
    8000286e:	7ef42623          	sw	a5,2028(s0)
    80002872:	fdaff0ef          	jal	8000204c <gem5_roi_begin>
    80002876:	f8eff0ef          	jal	80002004 <start_time>
    8000287a:	8526                	mv	a0,s1
    8000287c:	e33ff0ef          	jal	800026ae <iterate>
    80002880:	f92ff0ef          	jal	80002012 <stop_time>
    80002884:	f9cff0ef          	jal	80002020 <get_time>
    80002888:	8a2a                	mv	s4,a0
    8000288a:	fc4ff0ef          	jal	8000204e <gem5_roi_end>
    8000288e:	7c041503          	lh	a0,1984(s0)
    80002892:	4581                	li	a1,0
    80002894:	4fc010ef          	jal	80003d90 <crc16>
    80002898:	85aa                	mv	a1,a0
    8000289a:	7c241503          	lh	a0,1986(s0)
    8000289e:	4f2010ef          	jal	80003d90 <crc16>
    800028a2:	85aa                	mv	a1,a0
    800028a4:	7c441503          	lh	a0,1988(s0)
    800028a8:	4e8010ef          	jal	80003d90 <crc16>
    800028ac:	85aa                	mv	a1,a0
    800028ae:	7e841503          	lh	a0,2024(s0)
    800028b2:	4de010ef          	jal	80003d90 <crc16>
    800028b6:	67a1                	lui	a5,0x8
    800028b8:	0005099b          	sext.w	s3,a0
    800028bc:	b0578793          	addi	a5,a5,-1275 # 7b05 <_start-0x7fff84fb>
    800028c0:	42f98063          	beq	s3,a5,80002ce0 <main+0x5d6>
    800028c4:	0537fe63          	bgeu	a5,s3,80002920 <main+0x216>
    800028c8:	67a5                	lui	a5,0x9
    800028ca:	a0278793          	addi	a5,a5,-1534 # 8a02 <_start-0x7fff75fe>
    800028ce:	40f98163          	beq	s3,a5,80002cd0 <main+0x5c6>
    800028d2:	67bd                	lui	a5,0xf
    800028d4:	9f578793          	addi	a5,a5,-1547 # e9f5 <_start-0x7fff160b>
    800028d8:	14f99b63          	bne	s3,a5,80002a2e <main+0x324>
    800028dc:	00001517          	auipc	a0,0x1
    800028e0:	74450513          	addi	a0,a0,1860 # 80004020 <check_data_types+0xac>
    800028e4:	f52ff0ef          	jal	80002036 <ee_printf>
    800028e8:	4c0d                	li	s8,3
    800028ea:	a8a1                	j	80002942 <main+0x238>
    800028ec:	7c241603          	lh	a2,1986(s0)
    800028f0:	7c041783          	lh	a5,1984(s0)
    800028f4:	7d843583          	ld	a1,2008(s0)
    800028f8:	7e842503          	lw	a0,2024(s0)
    800028fc:	0106161b          	slliw	a2,a2,0x10
    80002900:	8e5d                	or	a2,a2,a5
    80002902:	2601                	sext.w	a2,a2
    80002904:	0894                	addi	a3,sp,80
    80002906:	41a000ef          	jal	80002d20 <core_init_matrix>
    8000290a:	7f042783          	lw	a5,2032(s0)
    8000290e:	b719                	j	80002814 <main+0x10a>
    80002910:	02b607bb          	mulw	a5,a2,a1
    80002914:	2605                	addiw	a2,a2,1
    80002916:	0806463b          	zext.h	a2,a2
    8000291a:	979a                	add	a5,a5,t1
    8000291c:	ea9c                	sd	a5,16(a3)
    8000291e:	b5d9                	j	800027e4 <main+0xda>
    80002920:	6789                	lui	a5,0x2
    80002922:	8f278793          	addi	a5,a5,-1806 # 18f2 <_start-0x7fffe70e>
    80002926:	38f98d63          	beq	s3,a5,80002cc0 <main+0x5b6>
    8000292a:	6795                	lui	a5,0x5
    8000292c:	eaf78793          	addi	a5,a5,-337 # 4eaf <_start-0x7fffb151>
    80002930:	0ef99f63          	bne	s3,a5,80002a2e <main+0x324>
    80002934:	00001517          	auipc	a0,0x1
    80002938:	6b450513          	addi	a0,a0,1716 # 80003fe8 <check_data_types+0x74>
    8000293c:	efaff0ef          	jal	80002036 <ee_printf>
    80002940:	4c09                	li	s8,2
    80002942:	00002797          	auipc	a5,0x2
    80002946:	e467a783          	lw	a5,-442(a5) # 80004788 <default_num_contexts>
    8000294a:	3a078a63          	beqz	a5,80002cfe <main+0x5f4>
    8000294e:	00002797          	auipc	a5,0x2
    80002952:	b5a78793          	addi	a5,a5,-1190 # 800044a8 <list_known_crc>
    80002956:	20fc2c33          	sh1add	s8,s8,a5
    8000295a:	4b81                	li	s7,0
    8000295c:	4a81                	li	s5,0
    8000295e:	4c81                	li	s9,0
    80002960:	6b05                	lui	s6,0x1
    80002962:	a035                	j	8000298e <main+0x284>
    80002964:	419487b3          	sub	a5,s1,s9
    80002968:	0792                	slli	a5,a5,0x4
    8000296a:	97a2                	add	a5,a5,s0
    8000296c:	97da                	add	a5,a5,s6
    8000296e:	8287d783          	lhu	a5,-2008(a5)
    80002972:	00fb893b          	addw	s2,s7,a5
    80002976:	00002797          	auipc	a5,0x2
    8000297a:	e127a783          	lw	a5,-494(a5) # 80004788 <default_num_contexts>
    8000297e:	2a85                	addiw	s5,s5,1
    80002980:	080accbb          	zext.h	s9,s5
    80002984:	8ae6                	mv	s5,s9
    80002986:	60591b93          	sext.h	s7,s2
    8000298a:	0afcf563          	bgeu	s9,a5,80002a34 <main+0x32a>
    8000298e:	003c9493          	slli	s1,s9,0x3
    80002992:	41948933          	sub	s2,s1,s9
    80002996:	0912                	slli	s2,s2,0x4
    80002998:	9922                	add	s2,s2,s0
    8000299a:	7f092783          	lw	a5,2032(s2)
    8000299e:	012b0d33          	add	s10,s6,s2
    800029a2:	820d1423          	sh	zero,-2008(s10)
    800029a6:	0017f713          	andi	a4,a5,1
    800029aa:	c70d                	beqz	a4,800029d4 <main+0x2ca>
    800029ac:	822d5603          	lhu	a2,-2014(s10)
    800029b0:	000c5683          	lhu	a3,0(s8)
    800029b4:	02d60063          	beq	a2,a3,800029d4 <main+0x2ca>
    800029b8:	85e6                	mv	a1,s9
    800029ba:	00001517          	auipc	a0,0x1
    800029be:	6c650513          	addi	a0,a0,1734 # 80004080 <check_data_types+0x10c>
    800029c2:	e74ff0ef          	jal	80002036 <ee_printf>
    800029c6:	828d5703          	lhu	a4,-2008(s10)
    800029ca:	7f092783          	lw	a5,2032(s2)
    800029ce:	2705                	addiw	a4,a4,1
    800029d0:	82ed1423          	sh	a4,-2008(s10)
    800029d4:	0027f713          	andi	a4,a5,2
    800029d8:	cb1d                	beqz	a4,80002a0e <main+0x304>
    800029da:	41948933          	sub	s2,s1,s9
    800029de:	0912                	slli	s2,s2,0x4
    800029e0:	9922                	add	s2,s2,s0
    800029e2:	012b0d33          	add	s10,s6,s2
    800029e6:	824d5603          	lhu	a2,-2012(s10)
    800029ea:	010c5683          	lhu	a3,16(s8)
    800029ee:	02d60063          	beq	a2,a3,80002a0e <main+0x304>
    800029f2:	85e6                	mv	a1,s9
    800029f4:	00001517          	auipc	a0,0x1
    800029f8:	6bc50513          	addi	a0,a0,1724 # 800040b0 <check_data_types+0x13c>
    800029fc:	e3aff0ef          	jal	80002036 <ee_printf>
    80002a00:	828d5703          	lhu	a4,-2008(s10)
    80002a04:	7f092783          	lw	a5,2032(s2)
    80002a08:	2705                	addiw	a4,a4,1
    80002a0a:	82ed1423          	sh	a4,-2008(s10)
    80002a0e:	8b91                	andi	a5,a5,4
    80002a10:	dbb1                	beqz	a5,80002964 <main+0x25a>
    80002a12:	419484b3          	sub	s1,s1,s9
    80002a16:	0492                	slli	s1,s1,0x4
    80002a18:	94a2                	add	s1,s1,s0
    80002a1a:	94da                	add	s1,s1,s6
    80002a1c:	8264d603          	lhu	a2,-2010(s1)
    80002a20:	020c5683          	lhu	a3,32(s8)
    80002a24:	1ed61163          	bne	a2,a3,80002c06 <main+0x4fc>
    80002a28:	8284d783          	lhu	a5,-2008(s1)
    80002a2c:	b799                	j	80002972 <main+0x268>
    80002a2e:	67c1                	lui	a5,0x10
    80002a30:	fff78913          	addi	s2,a5,-1 # ffff <_start-0x7fff0001>
    80002a34:	540010ef          	jal	80003f74 <check_data_types>
    80002a38:	7e846583          	lwu	a1,2024(s0)
    80002a3c:	0125093b          	addw	s2,a0,s2
    80002a40:	00001517          	auipc	a0,0x1
    80002a44:	6d850513          	addi	a0,a0,1752 # 80004118 <check_data_types+0x1a4>
    80002a48:	deeff0ef          	jal	80002036 <ee_printf>
    80002a4c:	080a05bb          	zext.w	a1,s4
    80002a50:	00001517          	auipc	a0,0x1
    80002a54:	6e050513          	addi	a0,a0,1760 # 80004130 <check_data_types+0x1bc>
    80002a58:	ddeff0ef          	jal	80002036 <ee_printf>
    80002a5c:	8552                	mv	a0,s4
    80002a5e:	dd6ff0ef          	jal	80002034 <time_in_secs>
    80002a62:	85aa                	mv	a1,a0
    80002a64:	00001517          	auipc	a0,0x1
    80002a68:	6e450513          	addi	a0,a0,1764 # 80004148 <check_data_types+0x1d4>
    80002a6c:	dcaff0ef          	jal	80002036 <ee_printf>
    80002a70:	8552                	mv	a0,s4
    80002a72:	dc2ff0ef          	jal	80002034 <time_in_secs>
    80002a76:	20051263          	bnez	a0,80002c7a <main+0x570>
    80002a7a:	8552                	mv	a0,s4
    80002a7c:	db8ff0ef          	jal	80002034 <time_in_secs>
    80002a80:	47a5                	li	a5,9
    80002a82:	1ea7f463          	bgeu	a5,a0,80002c6a <main+0x560>
    80002a86:	7ec46783          	lwu	a5,2028(s0)
    80002a8a:	00002597          	auipc	a1,0x2
    80002a8e:	cfe5e583          	lwu	a1,-770(a1) # 80004788 <default_num_contexts>
    80002a92:	00001517          	auipc	a0,0x1
    80002a96:	72650513          	addi	a0,a0,1830 # 800041b8 <check_data_types+0x244>
    80002a9a:	60591913          	sext.h	s2,s2
    80002a9e:	02f585b3          	mul	a1,a1,a5
    80002aa2:	d94ff0ef          	jal	80002036 <ee_printf>
    80002aa6:	00001597          	auipc	a1,0x1
    80002aaa:	72a58593          	addi	a1,a1,1834 # 800041d0 <check_data_types+0x25c>
    80002aae:	00001517          	auipc	a0,0x1
    80002ab2:	72a50513          	addi	a0,a0,1834 # 800041d8 <check_data_types+0x264>
    80002ab6:	d80ff0ef          	jal	80002036 <ee_printf>
    80002aba:	00001597          	auipc	a1,0x1
    80002abe:	73658593          	addi	a1,a1,1846 # 800041f0 <check_data_types+0x27c>
    80002ac2:	00001517          	auipc	a0,0x1
    80002ac6:	74650513          	addi	a0,a0,1862 # 80004208 <check_data_types+0x294>
    80002aca:	d6cff0ef          	jal	80002036 <ee_printf>
    80002ace:	00001597          	auipc	a1,0x1
    80002ad2:	75258593          	addi	a1,a1,1874 # 80004220 <check_data_types+0x2ac>
    80002ad6:	00001517          	auipc	a0,0x1
    80002ada:	75250513          	addi	a0,a0,1874 # 80004228 <check_data_types+0x2b4>
    80002ade:	d58ff0ef          	jal	80002036 <ee_printf>
    80002ae2:	85ce                	mv	a1,s3
    80002ae4:	00001517          	auipc	a0,0x1
    80002ae8:	75c50513          	addi	a0,a0,1884 # 80004240 <check_data_types+0x2cc>
    80002aec:	d4aff0ef          	jal	80002036 <ee_printf>
    80002af0:	7f042783          	lw	a5,2032(s0)
    80002af4:	8b85                	andi	a5,a5,1
    80002af6:	12079763          	bnez	a5,80002c24 <main+0x51a>
    80002afa:	00002797          	auipc	a5,0x2
    80002afe:	c8e7a783          	lw	a5,-882(a5) # 80004788 <default_num_contexts>
    80002b02:	7f042703          	lw	a4,2032(s0)
    80002b06:	00277693          	andi	a3,a4,2
    80002b0a:	ce9d                	beqz	a3,80002b48 <main+0x43e>
    80002b0c:	20078663          	beqz	a5,80002d18 <main+0x60e>
    80002b10:	4481                	li	s1,0
    80002b12:	4581                	li	a1,0
    80002b14:	6985                	lui	s3,0x1
    80002b16:	00359793          	slli	a5,a1,0x3
    80002b1a:	8f8d                	sub	a5,a5,a1
    80002b1c:	0792                	slli	a5,a5,0x4
    80002b1e:	97a2                	add	a5,a5,s0
    80002b20:	97ce                	add	a5,a5,s3
    80002b22:	8247d603          	lhu	a2,-2012(a5)
    80002b26:	00001517          	auipc	a0,0x1
    80002b2a:	75a50513          	addi	a0,a0,1882 # 80004280 <check_data_types+0x30c>
    80002b2e:	d08ff0ef          	jal	80002036 <ee_printf>
    80002b32:	00002797          	auipc	a5,0x2
    80002b36:	c567a783          	lw	a5,-938(a5) # 80004788 <default_num_contexts>
    80002b3a:	0014871b          	addiw	a4,s1,1
    80002b3e:	080745bb          	zext.h	a1,a4
    80002b42:	84ae                	mv	s1,a1
    80002b44:	fcf5e9e3          	bltu	a1,a5,80002b16 <main+0x40c>
    80002b48:	7f042703          	lw	a4,2032(s0)
    80002b4c:	8b11                	andi	a4,a4,4
    80002b4e:	cf15                	beqz	a4,80002b8a <main+0x480>
    80002b50:	4481                	li	s1,0
    80002b52:	4581                	li	a1,0
    80002b54:	6985                	lui	s3,0x1
    80002b56:	c7bd                	beqz	a5,80002bc4 <main+0x4ba>
    80002b58:	00359793          	slli	a5,a1,0x3
    80002b5c:	8f8d                	sub	a5,a5,a1
    80002b5e:	0792                	slli	a5,a5,0x4
    80002b60:	97a2                	add	a5,a5,s0
    80002b62:	97ce                	add	a5,a5,s3
    80002b64:	8267d603          	lhu	a2,-2010(a5)
    80002b68:	00001517          	auipc	a0,0x1
    80002b6c:	73850513          	addi	a0,a0,1848 # 800042a0 <check_data_types+0x32c>
    80002b70:	cc6ff0ef          	jal	80002036 <ee_printf>
    80002b74:	00002797          	auipc	a5,0x2
    80002b78:	c147a783          	lw	a5,-1004(a5) # 80004788 <default_num_contexts>
    80002b7c:	0014871b          	addiw	a4,s1,1
    80002b80:	080745bb          	zext.h	a1,a4
    80002b84:	84ae                	mv	s1,a1
    80002b86:	fcf5e9e3          	bltu	a1,a5,80002b58 <main+0x44e>
    80002b8a:	4481                	li	s1,0
    80002b8c:	4581                	li	a1,0
    80002b8e:	6985                	lui	s3,0x1
    80002b90:	cb95                	beqz	a5,80002bc4 <main+0x4ba>
    80002b92:	00359793          	slli	a5,a1,0x3
    80002b96:	8f8d                	sub	a5,a5,a1
    80002b98:	0792                	slli	a5,a5,0x4
    80002b9a:	97a2                	add	a5,a5,s0
    80002b9c:	97ce                	add	a5,a5,s3
    80002b9e:	8207d603          	lhu	a2,-2016(a5)
    80002ba2:	00001517          	auipc	a0,0x1
    80002ba6:	71e50513          	addi	a0,a0,1822 # 800042c0 <check_data_types+0x34c>
    80002baa:	c8cff0ef          	jal	80002036 <ee_printf>
    80002bae:	00002717          	auipc	a4,0x2
    80002bb2:	bda72703          	lw	a4,-1062(a4) # 80004788 <default_num_contexts>
    80002bb6:	0014879b          	addiw	a5,s1,1
    80002bba:	0807c5bb          	zext.h	a1,a5
    80002bbe:	84ae                	mv	s1,a1
    80002bc0:	fce5e9e3          	bltu	a1,a4,80002b92 <main+0x488>
    80002bc4:	0e090063          	beqz	s2,80002ca4 <main+0x59a>
    80002bc8:	0f205563          	blez	s2,80002cb2 <main+0x5a8>
    80002bcc:	00001517          	auipc	a0,0x1
    80002bd0:	7cc50513          	addi	a0,a0,1996 # 80004398 <check_data_types+0x424>
    80002bd4:	c62ff0ef          	jal	80002036 <ee_printf>
    80002bd8:	07a10513          	addi	a0,sp,122
    80002bdc:	c26ff0ef          	jal	80002002 <portable_fini>
    80002be0:	c70ff0ef          	jal	80002050 <gem5_bench_exit>
    80002be4:	7f010113          	addi	sp,sp,2032
    80002be8:	70ea                	ld	ra,184(sp)
    80002bea:	744a                	ld	s0,176(sp)
    80002bec:	74aa                	ld	s1,168(sp)
    80002bee:	790a                	ld	s2,160(sp)
    80002bf0:	69ea                	ld	s3,152(sp)
    80002bf2:	6a4a                	ld	s4,144(sp)
    80002bf4:	6aaa                	ld	s5,136(sp)
    80002bf6:	6b0a                	ld	s6,128(sp)
    80002bf8:	7be6                	ld	s7,120(sp)
    80002bfa:	7c46                	ld	s8,112(sp)
    80002bfc:	7ca6                	ld	s9,104(sp)
    80002bfe:	7d06                	ld	s10,96(sp)
    80002c00:	4501                	li	a0,0
    80002c02:	6129                	addi	sp,sp,192
    80002c04:	8082                	ret
    80002c06:	85e6                	mv	a1,s9
    80002c08:	00001517          	auipc	a0,0x1
    80002c0c:	4e050513          	addi	a0,a0,1248 # 800040e8 <check_data_types+0x174>
    80002c10:	c26ff0ef          	jal	80002036 <ee_printf>
    80002c14:	8284d783          	lhu	a5,-2008(s1)
    80002c18:	2785                	addiw	a5,a5,1
    80002c1a:	0807c7bb          	zext.h	a5,a5
    80002c1e:	82f49423          	sh	a5,-2008(s1)
    80002c22:	bb81                	j	80002972 <main+0x268>
    80002c24:	00002797          	auipc	a5,0x2
    80002c28:	b647a783          	lw	a5,-1180(a5) # 80004788 <default_num_contexts>
    80002c2c:	ec078be3          	beqz	a5,80002b02 <main+0x3f8>
    80002c30:	4481                	li	s1,0
    80002c32:	4581                	li	a1,0
    80002c34:	6985                	lui	s3,0x1
    80002c36:	00359793          	slli	a5,a1,0x3
    80002c3a:	8f8d                	sub	a5,a5,a1
    80002c3c:	0792                	slli	a5,a5,0x4
    80002c3e:	97a2                	add	a5,a5,s0
    80002c40:	97ce                	add	a5,a5,s3
    80002c42:	8227d603          	lhu	a2,-2014(a5)
    80002c46:	00001517          	auipc	a0,0x1
    80002c4a:	61a50513          	addi	a0,a0,1562 # 80004260 <check_data_types+0x2ec>
    80002c4e:	be8ff0ef          	jal	80002036 <ee_printf>
    80002c52:	00002797          	auipc	a5,0x2
    80002c56:	b367a783          	lw	a5,-1226(a5) # 80004788 <default_num_contexts>
    80002c5a:	0014871b          	addiw	a4,s1,1
    80002c5e:	080745bb          	zext.h	a1,a4
    80002c62:	84ae                	mv	s1,a1
    80002c64:	fcf5e9e3          	bltu	a1,a5,80002c36 <main+0x52c>
    80002c68:	bd69                	j	80002b02 <main+0x3f8>
    80002c6a:	00001517          	auipc	a0,0x1
    80002c6e:	50e50513          	addi	a0,a0,1294 # 80004178 <check_data_types+0x204>
    80002c72:	bc4ff0ef          	jal	80002036 <ee_printf>
    80002c76:	2905                	addiw	s2,s2,1
    80002c78:	b539                	j	80002a86 <main+0x37c>
    80002c7a:	7ec42783          	lw	a5,2028(s0)
    80002c7e:	00002497          	auipc	s1,0x2
    80002c82:	b0a4a483          	lw	s1,-1270(s1) # 80004788 <default_num_contexts>
    80002c86:	8552                	mv	a0,s4
    80002c88:	02f484bb          	mulw	s1,s1,a5
    80002c8c:	ba8ff0ef          	jal	80002034 <time_in_secs>
    80002c90:	85aa                	mv	a1,a0
    80002c92:	00001517          	auipc	a0,0x1
    80002c96:	4ce50513          	addi	a0,a0,1230 # 80004160 <check_data_types+0x1ec>
    80002c9a:	02b4d5bb          	divuw	a1,s1,a1
    80002c9e:	b98ff0ef          	jal	80002036 <ee_printf>
    80002ca2:	bbe1                	j	80002a7a <main+0x370>
    80002ca4:	00001517          	auipc	a0,0x1
    80002ca8:	63c50513          	addi	a0,a0,1596 # 800042e0 <check_data_types+0x36c>
    80002cac:	b8aff0ef          	jal	80002036 <ee_printf>
    80002cb0:	b725                	j	80002bd8 <main+0x4ce>
    80002cb2:	00001517          	auipc	a0,0x1
    80002cb6:	67e50513          	addi	a0,a0,1662 # 80004330 <check_data_types+0x3bc>
    80002cba:	b7cff0ef          	jal	80002036 <ee_printf>
    80002cbe:	bf29                	j	80002bd8 <main+0x4ce>
    80002cc0:	00001517          	auipc	a0,0x1
    80002cc4:	39050513          	addi	a0,a0,912 # 80004050 <check_data_types+0xdc>
    80002cc8:	b6eff0ef          	jal	80002036 <ee_printf>
    80002ccc:	4c11                	li	s8,4
    80002cce:	b995                	j	80002942 <main+0x238>
    80002cd0:	00001517          	auipc	a0,0x1
    80002cd4:	2b050513          	addi	a0,a0,688 # 80003f80 <check_data_types+0xc>
    80002cd8:	b5eff0ef          	jal	80002036 <ee_printf>
    80002cdc:	4c01                	li	s8,0
    80002cde:	b195                	j	80002942 <main+0x238>
    80002ce0:	00001517          	auipc	a0,0x1
    80002ce4:	2d850513          	addi	a0,a0,728 # 80003fb8 <check_data_types+0x44>
    80002ce8:	b4eff0ef          	jal	80002036 <ee_printf>
    80002cec:	4c05                	li	s8,1
    80002cee:	b991                	j	80002942 <main+0x238>
    80002cf0:	06600793          	li	a5,102
    80002cf4:	7c042023          	sw	zero,1984(s0)
    80002cf8:	7cf41223          	sh	a5,1988(s0)
    80002cfc:	b479                	j	8000278a <main+0x80>
    80002cfe:	4901                	li	s2,0
    80002d00:	bb15                	j	80002a34 <main+0x32a>
    80002d02:	341537b7          	lui	a5,0x34153
    80002d06:	41578793          	addi	a5,a5,1045 # 34153415 <_start-0x4beacbeb>
    80002d0a:	06600713          	li	a4,102
    80002d0e:	7cf42023          	sw	a5,1984(s0)
    80002d12:	7ce41223          	sh	a4,1988(s0)
    80002d16:	bc95                	j	8000278a <main+0x80>
    80002d18:	8b11                	andi	a4,a4,4
    80002d1a:	e60708e3          	beqz	a4,80002b8a <main+0x480>
    80002d1e:	b55d                	j	80002bc4 <main+0x4ba>

0000000080002d20 <core_init_matrix>:
    80002d20:	fff58e13          	addi	t3,a1,-1
    80002d24:	fff60793          	addi	a5,a2,-1
    80002d28:	ff8e7e13          	andi	t3,t3,-8
    80002d2c:	0ec7d7b3          	czero.eqz	a5,a5,a2
    80002d30:	85aa                	mv	a1,a0
    80002d32:	008e0e93          	addi	t4,t3,8
    80002d36:	0785                	addi	a5,a5,1
    80002d38:	4701                	li	a4,0
    80002d3a:	c559                	beqz	a0,80002dc8 <core_init_matrix+0xa8>
    80002d3c:	853a                	mv	a0,a4
    80002d3e:	2705                	addiw	a4,a4,1
    80002d40:	02e7063b          	mulw	a2,a4,a4
    80002d44:	0036161b          	slliw	a2,a2,0x3
    80002d48:	feb66ae3          	bltu	a2,a1,80002d3c <core_init_matrix+0x1c>
    80002d4c:	02a50e3b          	mulw	t3,a0,a0
    80002d50:	081e129b          	slli.uw	t0,t3,0x1
    80002d54:	21de2e3b          	sh1add.uw	t3,t3,t4
    80002d58:	cd2d                	beqz	a0,80002dd2 <core_init_matrix+0xb2>
    80002d5a:	83aa                	mv	t2,a0
    80002d5c:	0015031b          	addiw	t1,a0,1
    80002d60:	4f01                	li	t5,0
    80002d62:	4705                	li	a4,1
    80002d64:	8fba                	mv	t6,a4
    80002d66:	02e787bb          	mulw	a5,a5,a4
    80002d6a:	fff7061b          	addiw	a2,a4,-1
    80002d6e:	21c628bb          	sh1add.uw	a7,a2,t3
    80002d72:	21d6263b          	sh1add.uw	a2,a2,t4
    80002d76:	41f7d59b          	sraiw	a1,a5,0x1f
    80002d7a:	0105d59b          	srliw	a1,a1,0x10
    80002d7e:	9fad                	addw	a5,a5,a1
    80002d80:	0807c7bb          	zext.h	a5,a5
    80002d84:	9f8d                	subw	a5,a5,a1
    80002d86:	00e7883b          	addw	a6,a5,a4
    80002d8a:	00e805bb          	addw	a1,a6,a4
    80002d8e:	01089023          	sh	a6,0(a7)
    80002d92:	0ff5f593          	zext.b	a1,a1
    80002d96:	00b61023          	sh	a1,0(a2)
    80002d9a:	2705                	addiw	a4,a4,1
    80002d9c:	fc6715e3          	bne	a4,t1,80002d66 <core_init_matrix+0x46>
    80002da0:	2f05                	addiw	t5,t5,1 # ffffffffffff8001 <__bss_end+0xffffffff7fff3851>
    80002da2:	01f5073b          	addw	a4,a0,t6
    80002da6:	0065033b          	addw	t1,a0,t1
    80002daa:	faaf1de3          	bne	t5,a0,80002d64 <core_init_matrix+0x44>
    80002dae:	005e07b3          	add	a5,t3,t0
    80002db2:	17fd                	addi	a5,a5,-1
    80002db4:	9be1                	andi	a5,a5,-8
    80002db6:	07a1                	addi	a5,a5,8
    80002db8:	ee9c                	sd	a5,24(a3)
    80002dba:	01d6b423          	sd	t4,8(a3)
    80002dbe:	01c6b823          	sd	t3,16(a3)
    80002dc2:	0076a023          	sw	t2,0(a3)
    80002dc6:	8082                	ret
    80002dc8:	53fd                	li	t2,-1
    80002dca:	0e29                	addi	t3,t3,10
    80002dcc:	851e                	mv	a0,t2
    80002dce:	4289                	li	t0,2
    80002dd0:	b771                	j	80002d5c <core_init_matrix+0x3c>
    80002dd2:	4381                	li	t2,0
    80002dd4:	4281                	li	t0,0
    80002dd6:	bfe1                	j	80002dae <core_init_matrix+0x8e>

0000000080002dd8 <matrix_sum>:
    80002dd8:	8e2a                	mv	t3,a0
    80002dda:	c931                	beqz	a0,80002e2e <matrix_sum+0x56>
    80002ddc:	832a                	mv	t1,a0
    80002dde:	4f01                	li	t5,0
    80002de0:	4e81                	li	t4,0
    80002de2:	4501                	li	a0,0
    80002de4:	4701                	li	a4,0
    80002de6:	4801                	li	a6,0
    80002de8:	87fa                	mv	a5,t5
    80002dea:	a801                	j	80002dfa <matrix_sum+0x22>
    80002dec:	00a886bb          	addw	a3,a7,a0
    80002df0:	2785                	addiw	a5,a5,1
    80002df2:	60569513          	sext.h	a0,a3
    80002df6:	02f30463          	beq	t1,a5,80002e1e <matrix_sum+0x46>
    80002dfa:	88ba                	mv	a7,a4
    80002dfc:	20b7c73b          	sh2add.uw	a4,a5,a1
    80002e00:	4318                	lw	a4,0(a4)
    80002e02:	00a5069b          	addiw	a3,a0,10
    80002e06:	00e8083b          	addw	a6,a6,a4
    80002e0a:	00e8a8b3          	slt	a7,a7,a4
    80002e0e:	fd065fe3          	bge	a2,a6,80002dec <matrix_sum+0x14>
    80002e12:	2785                	addiw	a5,a5,1
    80002e14:	4801                	li	a6,0
    80002e16:	60569513          	sext.h	a0,a3
    80002e1a:	fef310e3          	bne	t1,a5,80002dfa <matrix_sum+0x22>
    80002e1e:	2e85                	addiw	t4,t4,1
    80002e20:	01c3033b          	addw	t1,t1,t3
    80002e24:	01cf0f3b          	addw	t5,t5,t3
    80002e28:	fdde10e3          	bne	t3,t4,80002de8 <matrix_sum+0x10>
    80002e2c:	8082                	ret
    80002e2e:	4501                	li	a0,0
    80002e30:	8082                	ret

0000000080002e32 <matrix_mul_const>:
    80002e32:	c90d                	beqz	a0,80002e64 <matrix_mul_const+0x32>
    80002e34:	88aa                	mv	a7,a0
    80002e36:	4e01                	li	t3,0
    80002e38:	4301                	li	t1,0
    80002e3a:	87f2                	mv	a5,t3
    80002e3c:	20c7a73b          	sh1add.uw	a4,a5,a2
    80002e40:	00071703          	lh	a4,0(a4)
    80002e44:	20b7c83b          	sh2add.uw	a6,a5,a1
    80002e48:	2785                	addiw	a5,a5,1
    80002e4a:	02d7073b          	mulw	a4,a4,a3
    80002e4e:	00e82023          	sw	a4,0(a6)
    80002e52:	fef895e3          	bne	a7,a5,80002e3c <matrix_mul_const+0xa>
    80002e56:	2305                	addiw	t1,t1,1
    80002e58:	01c50e3b          	addw	t3,a0,t3
    80002e5c:	011508bb          	addw	a7,a0,a7
    80002e60:	fc651de3          	bne	a0,t1,80002e3a <matrix_mul_const+0x8>
    80002e64:	8082                	ret

0000000080002e66 <matrix_add_const>:
    80002e66:	c515                	beqz	a0,80002e92 <matrix_add_const+0x2c>
    80002e68:	882a                	mv	a6,a0
    80002e6a:	4301                	li	t1,0
    80002e6c:	4881                	li	a7,0
    80002e6e:	879a                	mv	a5,t1
    80002e70:	20b7a6bb          	sh1add.uw	a3,a5,a1
    80002e74:	0006d703          	lhu	a4,0(a3)
    80002e78:	2785                	addiw	a5,a5,1
    80002e7a:	9f31                	addw	a4,a4,a2
    80002e7c:	00e69023          	sh	a4,0(a3)
    80002e80:	fef818e3          	bne	a6,a5,80002e70 <matrix_add_const+0xa>
    80002e84:	2885                	addiw	a7,a7,1
    80002e86:	0065033b          	addw	t1,a0,t1
    80002e8a:	0105083b          	addw	a6,a0,a6
    80002e8e:	ff1510e3          	bne	a0,a7,80002e6e <matrix_add_const+0x8>
    80002e92:	8082                	ret

0000000080002e94 <matrix_mul_vect>:
    80002e94:	cd15                	beqz	a0,80002ed0 <matrix_mul_vect+0x3c>
    80002e96:	20b54f3b          	sh2add.uw	t5,a0,a1
    80002e9a:	20d52e3b          	sh1add.uw	t3,a0,a3
    80002e9e:	4e81                	li	t4,0
    80002ea0:	87b6                	mv	a5,a3
    80002ea2:	8876                	mv	a6,t4
    80002ea4:	4881                	li	a7,0
    80002ea6:	20c8273b          	sh1add.uw	a4,a6,a2
    80002eaa:	00079303          	lh	t1,0(a5)
    80002eae:	00071703          	lh	a4,0(a4)
    80002eb2:	0789                	addi	a5,a5,2
    80002eb4:	2805                	addiw	a6,a6,1
    80002eb6:	0267073b          	mulw	a4,a4,t1
    80002eba:	011708bb          	addw	a7,a4,a7
    80002ebe:	fefe14e3          	bne	t3,a5,80002ea6 <matrix_mul_vect+0x12>
    80002ec2:	0115a023          	sw	a7,0(a1)
    80002ec6:	0591                	addi	a1,a1,4
    80002ec8:	01d50ebb          	addw	t4,a0,t4
    80002ecc:	fcbf1ae3          	bne	t5,a1,80002ea0 <matrix_mul_vect+0xc>
    80002ed0:	8082                	ret

0000000080002ed2 <matrix_mul_matrix>:
    80002ed2:	8e2a                	mv	t3,a0
    80002ed4:	4f81                	li	t6,0
    80002ed6:	4281                	li	t0,0
    80002ed8:	c939                	beqz	a0,80002f2e <matrix_mul_matrix+0x5c>
    80002eda:	4e81                	li	t4,0
    80002edc:	01fe8f3b          	addw	t5,t4,t6
    80002ee0:	20bf4f3b          	sh2add.uw	t5,t5,a1
    80002ee4:	8876                	mv	a6,t4
    80002ee6:	87fe                	mv	a5,t6
    80002ee8:	4881                	li	a7,0
    80002eea:	20c7a73b          	sh1add.uw	a4,a5,a2
    80002eee:	20d8233b          	sh1add.uw	t1,a6,a3
    80002ef2:	00071703          	lh	a4,0(a4)
    80002ef6:	00031303          	lh	t1,0(t1)
    80002efa:	2785                	addiw	a5,a5,1
    80002efc:	0105083b          	addw	a6,a0,a6
    80002f00:	0267073b          	mulw	a4,a4,t1
    80002f04:	011708bb          	addw	a7,a4,a7
    80002f08:	fefe11e3          	bne	t3,a5,80002eea <matrix_mul_matrix+0x18>
    80002f0c:	011f2023          	sw	a7,0(t5)
    80002f10:	001e879b          	addiw	a5,t4,1
    80002f14:	00f50463          	beq	a0,a5,80002f1c <matrix_mul_matrix+0x4a>
    80002f18:	8ebe                	mv	t4,a5
    80002f1a:	b7c9                	j	80002edc <matrix_mul_matrix+0xa>
    80002f1c:	01f50fbb          	addw	t6,a0,t6
    80002f20:	01c50e3b          	addw	t3,a0,t3
    80002f24:	01d28463          	beq	t0,t4,80002f2c <matrix_mul_matrix+0x5a>
    80002f28:	2285                	addiw	t0,t0,1
    80002f2a:	bf45                	j	80002eda <matrix_mul_matrix+0x8>
    80002f2c:	8082                	ret
    80002f2e:	8082                	ret

0000000080002f30 <matrix_mul_matrix_bitextract>:
    80002f30:	8e2a                	mv	t3,a0
    80002f32:	4281                	li	t0,0
    80002f34:	4381                	li	t2,0
    80002f36:	c52d                	beqz	a0,80002fa0 <matrix_mul_matrix_bitextract+0x70>
    80002f38:	4f01                	li	t5,0
    80002f3a:	005f0fbb          	addw	t6,t5,t0
    80002f3e:	20bfcfbb          	sh2add.uw	t6,t6,a1
    80002f42:	88fa                	mv	a7,t5
    80002f44:	8716                	mv	a4,t0
    80002f46:	4301                	li	t1,0
    80002f48:	20c727bb          	sh1add.uw	a5,a4,a2
    80002f4c:	20d8a83b          	sh1add.uw	a6,a7,a3
    80002f50:	00081803          	lh	a6,0(a6)
    80002f54:	00079783          	lh	a5,0(a5)
    80002f58:	2705                	addiw	a4,a4,1
    80002f5a:	011508bb          	addw	a7,a0,a7
    80002f5e:	030787bb          	mulw	a5,a5,a6
    80002f62:	03a79e93          	slli	t4,a5,0x3a
    80002f66:	03ced813          	srli	a6,t4,0x3c
    80002f6a:	03479e93          	slli	t4,a5,0x34
    80002f6e:	039ed793          	srli	a5,t4,0x39
    80002f72:	02f807bb          	mulw	a5,a6,a5
    80002f76:	0067833b          	addw	t1,a5,t1
    80002f7a:	fcee17e3          	bne	t3,a4,80002f48 <matrix_mul_matrix_bitextract+0x18>
    80002f7e:	006fa023          	sw	t1,0(t6)
    80002f82:	001f079b          	addiw	a5,t5,1
    80002f86:	00f50463          	beq	a0,a5,80002f8e <matrix_mul_matrix_bitextract+0x5e>
    80002f8a:	8f3e                	mv	t5,a5
    80002f8c:	b77d                	j	80002f3a <matrix_mul_matrix_bitextract+0xa>
    80002f8e:	005502bb          	addw	t0,a0,t0
    80002f92:	01c50e3b          	addw	t3,a0,t3
    80002f96:	01e38463          	beq	t2,t5,80002f9e <matrix_mul_matrix_bitextract+0x6e>
    80002f9a:	2385                	addiw	t2,t2,1
    80002f9c:	bf71                	j	80002f38 <matrix_mul_matrix_bitextract+0x8>
    80002f9e:	8082                	ret
    80002fa0:	8082                	ret

0000000080002fa2 <matrix_test>:
    80002fa2:	715d                	addi	sp,sp,-80
    80002fa4:	e0a2                	sd	s0,64(sp)
    80002fa6:	f44e                	sd	s3,40(sp)
    80002fa8:	f052                	sd	s4,32(sp)
    80002faa:	e486                	sd	ra,72(sp)
    80002fac:	fc26                	sd	s1,56(sp)
    80002fae:	842e                	mv	s0,a1
    80002fb0:	8a32                	mv	s4,a2
    80002fb2:	89b6                	mv	s3,a3
    80002fb4:	22050563          	beqz	a0,800031de <matrix_test+0x23c>
    80002fb8:	f84a                	sd	s2,48(sp)
    80002fba:	797d                	lui	s2,0xfffff
    80002fbc:	ec56                	sd	s5,24(sp)
    80002fbe:	e85a                	sd	s6,16(sp)
    80002fc0:	e45e                	sd	s7,8(sp)
    80002fc2:	8aba                	mv	s5,a4
    80002fc4:	01276933          	or	s2,a4,s2
    80002fc8:	862a                	mv	a2,a0
    80002fca:	4581                	li	a1,0
    80002fcc:	4b01                	li	s6,0
    80002fce:	87ae                	mv	a5,a1
    80002fd0:	2147a6bb          	sh1add.uw	a3,a5,s4
    80002fd4:	0006d703          	lhu	a4,0(a3)
    80002fd8:	2785                	addiw	a5,a5,1
    80002fda:	0157073b          	addw	a4,a4,s5
    80002fde:	00e69023          	sh	a4,0(a3)
    80002fe2:	fef617e3          	bne	a2,a5,80002fd0 <matrix_test+0x2e>
    80002fe6:	001b049b          	addiw	s1,s6,1 # 1001 <_start-0x7fffefff>
    80002fea:	9da9                	addw	a1,a1,a0
    80002fec:	9e29                	addw	a2,a2,a0
    80002fee:	00950463          	beq	a0,s1,80002ff6 <matrix_test+0x54>
    80002ff2:	8b26                	mv	s6,s1
    80002ff4:	bfe9                	j	80002fce <matrix_test+0x2c>
    80002ff6:	8626                	mv	a2,s1
    80002ff8:	4581                	li	a1,0
    80002ffa:	4501                	li	a0,0
    80002ffc:	87ae                	mv	a5,a1
    80002ffe:	2147a73b          	sh1add.uw	a4,a5,s4
    80003002:	00071703          	lh	a4,0(a4)
    80003006:	2087c6bb          	sh2add.uw	a3,a5,s0
    8000300a:	2785                	addiw	a5,a5,1
    8000300c:	0357073b          	mulw	a4,a4,s5
    80003010:	c298                	sw	a4,0(a3)
    80003012:	fec796e3          	bne	a5,a2,80002ffe <matrix_test+0x5c>
    80003016:	9da5                	addw	a1,a1,s1
    80003018:	9e25                	addw	a2,a2,s1
    8000301a:	01650463          	beq	a0,s6,80003022 <matrix_test+0x80>
    8000301e:	2505                	addiw	a0,a0,1
    80003020:	bff1                	j	80002ffc <matrix_test+0x5a>
    80003022:	8826                	mv	a6,s1
    80003024:	4881                	li	a7,0
    80003026:	4681                	li	a3,0
    80003028:	4601                	li	a2,0
    8000302a:	4501                	li	a0,0
    8000302c:	4301                	li	t1,0
    8000302e:	87c6                	mv	a5,a7
    80003030:	a801                	j	80003040 <matrix_test+0x9e>
    80003032:	00a5873b          	addw	a4,a1,a0
    80003036:	2785                	addiw	a5,a5,1
    80003038:	60571513          	sext.h	a0,a4
    8000303c:	03078363          	beq	a5,a6,80003062 <matrix_test+0xc0>
    80003040:	2087c73b          	sh2add.uw	a4,a5,s0
    80003044:	85b6                	mv	a1,a3
    80003046:	4314                	lw	a3,0(a4)
    80003048:	00a5071b          	addiw	a4,a0,10
    8000304c:	9e35                	addw	a2,a2,a3
    8000304e:	00d5a5b3          	slt	a1,a1,a3
    80003052:	fec950e3          	bge	s2,a2,80003032 <matrix_test+0x90>
    80003056:	2785                	addiw	a5,a5,1
    80003058:	4601                	li	a2,0
    8000305a:	60571513          	sext.h	a0,a4
    8000305e:	ff0791e3          	bne	a5,a6,80003040 <matrix_test+0x9e>
    80003062:	00f4883b          	addw	a6,s1,a5
    80003066:	011488bb          	addw	a7,s1,a7
    8000306a:	006b0463          	beq	s6,t1,80003072 <matrix_test+0xd0>
    8000306e:	2305                	addiw	t1,t1,1
    80003070:	bf7d                	j	8000302e <matrix_test+0x8c>
    80003072:	4581                	li	a1,0
    80003074:	51d000ef          	jal	80003d90 <crc16>
    80003078:	86ce                	mv	a3,s3
    8000307a:	8652                	mv	a2,s4
    8000307c:	8baa                	mv	s7,a0
    8000307e:	85a2                	mv	a1,s0
    80003080:	8526                	mv	a0,s1
    80003082:	e13ff0ef          	jal	80002e94 <matrix_mul_vect>
    80003086:	8826                	mv	a6,s1
    80003088:	4881                	li	a7,0
    8000308a:	4681                	li	a3,0
    8000308c:	4601                	li	a2,0
    8000308e:	4501                	li	a0,0
    80003090:	4301                	li	t1,0
    80003092:	87c6                	mv	a5,a7
    80003094:	a801                	j	800030a4 <matrix_test+0x102>
    80003096:	00a5873b          	addw	a4,a1,a0
    8000309a:	2785                	addiw	a5,a5,1
    8000309c:	60571513          	sext.h	a0,a4
    800030a0:	03078363          	beq	a5,a6,800030c6 <matrix_test+0x124>
    800030a4:	2087c73b          	sh2add.uw	a4,a5,s0
    800030a8:	85b6                	mv	a1,a3
    800030aa:	4314                	lw	a3,0(a4)
    800030ac:	00a5071b          	addiw	a4,a0,10
    800030b0:	9e35                	addw	a2,a2,a3
    800030b2:	00d5a5b3          	slt	a1,a1,a3
    800030b6:	fec950e3          	bge	s2,a2,80003096 <matrix_test+0xf4>
    800030ba:	2785                	addiw	a5,a5,1
    800030bc:	4601                	li	a2,0
    800030be:	60571513          	sext.h	a0,a4
    800030c2:	ff0791e3          	bne	a5,a6,800030a4 <matrix_test+0x102>
    800030c6:	00f4883b          	addw	a6,s1,a5
    800030ca:	011488bb          	addw	a7,s1,a7
    800030ce:	01630463          	beq	t1,s6,800030d6 <matrix_test+0x134>
    800030d2:	2305                	addiw	t1,t1,1
    800030d4:	bf7d                	j	80003092 <matrix_test+0xf0>
    800030d6:	85de                	mv	a1,s7
    800030d8:	4b9000ef          	jal	80003d90 <crc16>
    800030dc:	86ce                	mv	a3,s3
    800030de:	8652                	mv	a2,s4
    800030e0:	8b2a                	mv	s6,a0
    800030e2:	85a2                	mv	a1,s0
    800030e4:	8526                	mv	a0,s1
    800030e6:	dedff0ef          	jal	80002ed2 <matrix_mul_matrix>
    800030ea:	4801                	li	a6,0
    800030ec:	4681                	li	a3,0
    800030ee:	4601                	li	a2,0
    800030f0:	4501                	li	a0,0
    800030f2:	4881                	li	a7,0
    800030f4:	4781                	li	a5,0
    800030f6:	a801                	j	80003106 <matrix_test+0x164>
    800030f8:	00a5873b          	addw	a4,a1,a0
    800030fc:	2785                	addiw	a5,a5,1
    800030fe:	60571513          	sext.h	a0,a4
    80003102:	0297f563          	bgeu	a5,s1,8000312c <matrix_test+0x18a>
    80003106:	0107873b          	addw	a4,a5,a6
    8000310a:	2087473b          	sh2add.uw	a4,a4,s0
    8000310e:	85b6                	mv	a1,a3
    80003110:	4314                	lw	a3,0(a4)
    80003112:	00a5071b          	addiw	a4,a0,10
    80003116:	9e35                	addw	a2,a2,a3
    80003118:	00d5a5b3          	slt	a1,a1,a3
    8000311c:	fcc95ee3          	bge	s2,a2,800030f8 <matrix_test+0x156>
    80003120:	2785                	addiw	a5,a5,1
    80003122:	4601                	li	a2,0
    80003124:	60571513          	sext.h	a0,a4
    80003128:	fc97efe3          	bltu	a5,s1,80003106 <matrix_test+0x164>
    8000312c:	2885                	addiw	a7,a7,1
    8000312e:	0104883b          	addw	a6,s1,a6
    80003132:	fc98e1e3          	bltu	a7,s1,800030f4 <matrix_test+0x152>
    80003136:	85da                	mv	a1,s6
    80003138:	459000ef          	jal	80003d90 <crc16>
    8000313c:	86ce                	mv	a3,s3
    8000313e:	8b2a                	mv	s6,a0
    80003140:	8652                	mv	a2,s4
    80003142:	8526                	mv	a0,s1
    80003144:	85a2                	mv	a1,s0
    80003146:	debff0ef          	jal	80002f30 <matrix_mul_matrix_bitextract>
    8000314a:	4801                	li	a6,0
    8000314c:	4681                	li	a3,0
    8000314e:	4701                	li	a4,0
    80003150:	4501                	li	a0,0
    80003152:	4881                	li	a7,0
    80003154:	4781                	li	a5,0
    80003156:	a801                	j	80003166 <matrix_test+0x1c4>
    80003158:	00a605bb          	addw	a1,a2,a0
    8000315c:	2785                	addiw	a5,a5,1
    8000315e:	60559513          	sext.h	a0,a1
    80003162:	0297f563          	bgeu	a5,s1,8000318c <matrix_test+0x1ea>
    80003166:	00f805bb          	addw	a1,a6,a5
    8000316a:	2085c5bb          	sh2add.uw	a1,a1,s0
    8000316e:	8636                	mv	a2,a3
    80003170:	4194                	lw	a3,0(a1)
    80003172:	00a5059b          	addiw	a1,a0,10
    80003176:	9f35                	addw	a4,a4,a3
    80003178:	00d62633          	slt	a2,a2,a3
    8000317c:	fce95ee3          	bge	s2,a4,80003158 <matrix_test+0x1b6>
    80003180:	2785                	addiw	a5,a5,1
    80003182:	4701                	li	a4,0
    80003184:	60559513          	sext.h	a0,a1
    80003188:	fc97efe3          	bltu	a5,s1,80003166 <matrix_test+0x1c4>
    8000318c:	2885                	addiw	a7,a7,1
    8000318e:	0098083b          	addw	a6,a6,s1
    80003192:	fc98e1e3          	bltu	a7,s1,80003154 <matrix_test+0x1b2>
    80003196:	85da                	mv	a1,s6
    80003198:	3f9000ef          	jal	80003d90 <crc16>
    8000319c:	4701                	li	a4,0
    8000319e:	4601                	li	a2,0
    800031a0:	4681                	li	a3,0
    800031a2:	00e687bb          	addw	a5,a3,a4
    800031a6:	2147a7bb          	sh1add.uw	a5,a5,s4
    800031aa:	0007d583          	lhu	a1,0(a5)
    800031ae:	2685                	addiw	a3,a3,1
    800031b0:	415585bb          	subw	a1,a1,s5
    800031b4:	00b79023          	sh	a1,0(a5)
    800031b8:	fe96e5e3          	bltu	a3,s1,800031a2 <matrix_test+0x200>
    800031bc:	2605                	addiw	a2,a2,1
    800031be:	9f25                	addw	a4,a4,s1
    800031c0:	fe9660e3          	bltu	a2,s1,800031a0 <matrix_test+0x1fe>
    800031c4:	60a6                	ld	ra,72(sp)
    800031c6:	6406                	ld	s0,64(sp)
    800031c8:	7942                	ld	s2,48(sp)
    800031ca:	6ae2                	ld	s5,24(sp)
    800031cc:	6b42                	ld	s6,16(sp)
    800031ce:	6ba2                	ld	s7,8(sp)
    800031d0:	74e2                	ld	s1,56(sp)
    800031d2:	79a2                	ld	s3,40(sp)
    800031d4:	7a02                	ld	s4,32(sp)
    800031d6:	60551513          	sext.h	a0,a0
    800031da:	6161                	addi	sp,sp,80
    800031dc:	8082                	ret
    800031de:	4581                	li	a1,0
    800031e0:	3b1000ef          	jal	80003d90 <crc16>
    800031e4:	86ce                	mv	a3,s3
    800031e6:	8652                	mv	a2,s4
    800031e8:	84aa                	mv	s1,a0
    800031ea:	85a2                	mv	a1,s0
    800031ec:	4501                	li	a0,0
    800031ee:	ca7ff0ef          	jal	80002e94 <matrix_mul_vect>
    800031f2:	85a6                	mv	a1,s1
    800031f4:	4501                	li	a0,0
    800031f6:	39b000ef          	jal	80003d90 <crc16>
    800031fa:	86ce                	mv	a3,s3
    800031fc:	8652                	mv	a2,s4
    800031fe:	84aa                	mv	s1,a0
    80003200:	85a2                	mv	a1,s0
    80003202:	4501                	li	a0,0
    80003204:	ccfff0ef          	jal	80002ed2 <matrix_mul_matrix>
    80003208:	85a6                	mv	a1,s1
    8000320a:	4501                	li	a0,0
    8000320c:	385000ef          	jal	80003d90 <crc16>
    80003210:	84aa                	mv	s1,a0
    80003212:	86ce                	mv	a3,s3
    80003214:	8652                	mv	a2,s4
    80003216:	85a2                	mv	a1,s0
    80003218:	4501                	li	a0,0
    8000321a:	d17ff0ef          	jal	80002f30 <matrix_mul_matrix_bitextract>
    8000321e:	85a6                	mv	a1,s1
    80003220:	4501                	li	a0,0
    80003222:	36f000ef          	jal	80003d90 <crc16>
    80003226:	60a6                	ld	ra,72(sp)
    80003228:	6406                	ld	s0,64(sp)
    8000322a:	74e2                	ld	s1,56(sp)
    8000322c:	79a2                	ld	s3,40(sp)
    8000322e:	7a02                	ld	s4,32(sp)
    80003230:	60551513          	sext.h	a0,a0
    80003234:	6161                	addi	sp,sp,80
    80003236:	8082                	ret

0000000080003238 <core_bench_matrix>:
    80003238:	1141                	addi	sp,sp,-16
    8000323a:	e022                	sd	s0,0(sp)
    8000323c:	6914                	ld	a3,16(a0)
    8000323e:	8432                	mv	s0,a2
    80003240:	872e                	mv	a4,a1
    80003242:	6510                	ld	a2,8(a0)
    80003244:	6d0c                	ld	a1,24(a0)
    80003246:	4108                	lw	a0,0(a0)
    80003248:	e406                	sd	ra,8(sp)
    8000324a:	d59ff0ef          	jal	80002fa2 <matrix_test>
    8000324e:	85a2                	mv	a1,s0
    80003250:	6402                	ld	s0,0(sp)
    80003252:	60a2                	ld	ra,8(sp)
    80003254:	0141                	addi	sp,sp,16
    80003256:	33b0006f          	j	80003d90 <crc16>

000000008000325a <core_init_state>:
    8000325a:	fff50e1b          	addiw	t3,a0,-1
    8000325e:	4f85                	li	t6,1
    80003260:	11cff063          	bgeu	t6,t3,80003360 <core_init_state+0x106>
    80003264:	2585                	addiw	a1,a1,1
    80003266:	03b59893          	slli	a7,a1,0x3b
    8000326a:	4e9d                	li	t4,7
    8000326c:	0075f813          	andi	a6,a1,7
    80003270:	4701                	li	a4,0
    80003272:	00001f17          	auipc	t5,0x1
    80003276:	266f0f13          	addi	t5,t5,614 # 800044d8 <intpat>
    8000327a:	4291                	li	t0,4
    8000327c:	02c00393          	li	t2,44
    80003280:	03e8d793          	srli	a5,a7,0x3e
    80003284:	0dd80963          	beq	a6,t4,80003356 <core_init_state+0xfc>
    80003288:	0b02e263          	bltu	t0,a6,8000332c <core_init_state+0xd2>
    8000328c:	ffd8069b          	addiw	a3,a6,-3
    80003290:	0806c6bb          	zext.h	a3,a3
    80003294:	21e7e7b3          	sh3add	a5,a5,t5
    80003298:	0adfec63          	bltu	t6,a3,80003350 <core_init_state+0xf6>
    8000329c:	739c                	ld	a5,32(a5)
    8000329e:	46a1                	li	a3,8
    800032a0:	0017089b          	addiw	a7,a4,1
    800032a4:	00d888bb          	addw	a7,a7,a3
    800032a8:	0dc8f763          	bgeu	a7,t3,80003376 <core_init_state+0x11c>
    800032ac:	1141                	addi	sp,sp,-16
    800032ae:	e422                	sd	s0,8(sp)
    800032b0:	00d78333          	add	t1,a5,a3
    800032b4:	0807043b          	zext.w	s0,a4
    800032b8:	2585                	addiw	a1,a1,1
    800032ba:	080686bb          	zext.w	a3,a3
    800032be:	08c7073b          	add.uw	a4,a4,a2
    800032c2:	0007c803          	lbu	a6,0(a5)
    800032c6:	0785                	addi	a5,a5,1
    800032c8:	0705                	addi	a4,a4,1
    800032ca:	ff070fa3          	sb	a6,-1(a4)
    800032ce:	fe679ae3          	bne	a5,t1,800032c2 <core_init_state+0x68>
    800032d2:	96b2                	add	a3,a3,a2
    800032d4:	96a2                	add	a3,a3,s0
    800032d6:	8746                	mv	a4,a7
    800032d8:	00768023          	sb	t2,0(a3)
    800032dc:	03b59893          	slli	a7,a1,0x3b
    800032e0:	0075f813          	andi	a6,a1,7
    800032e4:	03e8d793          	srli	a5,a7,0x3e
    800032e8:	05d80c63          	beq	a6,t4,80003340 <core_init_state+0xe6>
    800032ec:	0502e563          	bltu	t0,a6,80003336 <core_init_state+0xdc>
    800032f0:	ffd8069b          	addiw	a3,a6,-3
    800032f4:	0806c6bb          	zext.h	a3,a3
    800032f8:	21e7e7b3          	sh3add	a5,a5,t5
    800032fc:	04dfe763          	bltu	t6,a3,8000334a <core_init_state+0xf0>
    80003300:	739c                	ld	a5,32(a5)
    80003302:	46a1                	li	a3,8
    80003304:	0017089b          	addiw	a7,a4,1
    80003308:	00d888bb          	addw	a7,a7,a3
    8000330c:	fbc8e2e3          	bltu	a7,t3,800032b0 <core_init_state+0x56>
    80003310:	08c707bb          	add.uw	a5,a4,a2
    80003314:	00a77963          	bgeu	a4,a0,80003326 <core_init_state+0xcc>
    80003318:	00078023          	sb	zero,0(a5)
    8000331c:	0785                	addi	a5,a5,1
    8000331e:	40c7873b          	subw	a4,a5,a2
    80003322:	fea76be3          	bltu	a4,a0,80003318 <core_init_state+0xbe>
    80003326:	6422                	ld	s0,8(sp)
    80003328:	0141                	addi	sp,sp,16
    8000332a:	8082                	ret
    8000332c:	21e7e7b3          	sh3add	a5,a5,t5
    80003330:	63bc                	ld	a5,64(a5)
    80003332:	46a1                	li	a3,8
    80003334:	b7b5                	j	800032a0 <core_init_state+0x46>
    80003336:	21e7e7b3          	sh3add	a5,a5,t5
    8000333a:	63bc                	ld	a5,64(a5)
    8000333c:	46a1                	li	a3,8
    8000333e:	b7d9                	j	80003304 <core_init_state+0xaa>
    80003340:	21e7e7b3          	sh3add	a5,a5,t5
    80003344:	73bc                	ld	a5,96(a5)
    80003346:	46a1                	li	a3,8
    80003348:	bf75                	j	80003304 <core_init_state+0xaa>
    8000334a:	639c                	ld	a5,0(a5)
    8000334c:	4691                	li	a3,4
    8000334e:	bf5d                	j	80003304 <core_init_state+0xaa>
    80003350:	639c                	ld	a5,0(a5)
    80003352:	4691                	li	a3,4
    80003354:	b7b1                	j	800032a0 <core_init_state+0x46>
    80003356:	21e7e7b3          	sh3add	a5,a5,t5
    8000335a:	73bc                	ld	a5,96(a5)
    8000335c:	46a1                	li	a3,8
    8000335e:	b789                	j	800032a0 <core_init_state+0x46>
    80003360:	4701                	li	a4,0
    80003362:	08c707bb          	add.uw	a5,a4,a2
    80003366:	00078023          	sb	zero,0(a5)
    8000336a:	0785                	addi	a5,a5,1
    8000336c:	40c7873b          	subw	a4,a5,a2
    80003370:	fea76be3          	bltu	a4,a0,80003366 <core_init_state+0x10c>
    80003374:	8082                	ret
    80003376:	fea766e3          	bltu	a4,a0,80003362 <core_init_state+0x108>
    8000337a:	8082                	ret

000000008000337c <core_state_transition>:
    8000337c:	6114                	ld	a3,0(a0)
    8000337e:	0006c783          	lbu	a5,0(a3)
    80003382:	cb8d                	beqz	a5,800033b4 <core_state_transition+0x38>
    80003384:	02c00713          	li	a4,44
    80003388:	16e78a63          	beq	a5,a4,800034fc <core_state_transition+0x180>
    8000338c:	02e00813          	li	a6,46
    80003390:	15078b63          	beq	a5,a6,800034e6 <core_state_transition+0x16a>
    80003394:	02f86363          	bltu	a6,a5,800033ba <core_state_transition+0x3e>
    80003398:	fd57879b          	addiw	a5,a5,-43
    8000339c:	0fd7f793          	andi	a5,a5,253
    800033a0:	16078163          	beqz	a5,80003502 <core_state_transition+0x186>
    800033a4:	41d8                	lw	a4,4(a1)
    800033a6:	419c                	lw	a5,0(a1)
    800033a8:	0685                	addi	a3,a3,1
    800033aa:	2705                	addiw	a4,a4,1
    800033ac:	2785                	addiw	a5,a5,1
    800033ae:	c19c                	sw	a5,0(a1)
    800033b0:	c1d8                	sw	a4,4(a1)
    800033b2:	4785                	li	a5,1
    800033b4:	e114                	sd	a3,0(a0)
    800033b6:	853e                	mv	a0,a5
    800033b8:	8082                	ret
    800033ba:	fd07879b          	addiw	a5,a5,-48
    800033be:	0ff7f793          	zext.b	a5,a5
    800033c2:	4625                	li	a2,9
    800033c4:	fef660e3          	bltu	a2,a5,800033a4 <core_state_transition+0x28>
    800033c8:	4190                	lw	a2,0(a1)
    800033ca:	00168793          	addi	a5,a3,1
    800033ce:	2605                	addiw	a2,a2,1
    800033d0:	c190                	sw	a2,0(a1)
    800033d2:	0016c683          	lbu	a3,1(a3)
    800033d6:	16068263          	beqz	a3,8000353a <core_state_transition+0x1be>
    800033da:	16e68763          	beq	a3,a4,80003548 <core_state_transition+0x1cc>
    800033de:	02e00713          	li	a4,46
    800033e2:	02e68b63          	beq	a3,a4,80003418 <core_state_transition+0x9c>
    800033e6:	fd06869b          	addiw	a3,a3,-48
    800033ea:	0ff6f693          	zext.b	a3,a3
    800033ee:	4725                	li	a4,9
    800033f0:	00d77c63          	bgeu	a4,a3,80003408 <core_state_transition+0x8c>
    800033f4:	4998                	lw	a4,16(a1)
    800033f6:	00178693          	addi	a3,a5,1
    800033fa:	4785                	li	a5,1
    800033fc:	2705                	addiw	a4,a4,1
    800033fe:	c998                	sw	a4,16(a1)
    80003400:	e114                	sd	a3,0(a0)
    80003402:	853e                	mv	a0,a5
    80003404:	8082                	ret
    80003406:	c590                	sw	a2,8(a1)
    80003408:	0017c683          	lbu	a3,1(a5)
    8000340c:	0785                	addi	a5,a5,1
    8000340e:	12068663          	beqz	a3,8000353a <core_state_transition+0x1be>
    80003412:	02c00713          	li	a4,44
    80003416:	b7d1                	j	800033da <core_state_transition+0x5e>
    80003418:	4998                	lw	a4,16(a1)
    8000341a:	2705                	addiw	a4,a4,1
    8000341c:	c998                	sw	a4,16(a1)
    8000341e:	0017c683          	lbu	a3,1(a5)
    80003422:	0785                	addi	a5,a5,1
    80003424:	cae9                	beqz	a3,800034f6 <core_state_transition+0x17a>
    80003426:	02c00713          	li	a4,44
    8000342a:	10e68b63          	beq	a3,a4,80003540 <core_state_transition+0x1c4>
    8000342e:	0df6f713          	andi	a4,a3,223
    80003432:	04500613          	li	a2,69
    80003436:	08c71a63          	bne	a4,a2,800034ca <core_state_transition+0x14e>
    8000343a:	49d8                	lw	a4,20(a1)
    8000343c:	00178693          	addi	a3,a5,1
    80003440:	2705                	addiw	a4,a4,1
    80003442:	c9d8                	sw	a4,20(a1)
    80003444:	0017c703          	lbu	a4,1(a5)
    80003448:	10070663          	beqz	a4,80003554 <core_state_transition+0x1d8>
    8000344c:	02c00613          	li	a2,44
    80003450:	10c70463          	beq	a4,a2,80003558 <core_state_transition+0x1dc>
    80003454:	45d4                	lw	a3,12(a1)
    80003456:	fd57071b          	addiw	a4,a4,-43
    8000345a:	0fd77713          	andi	a4,a4,253
    8000345e:	2685                	addiw	a3,a3,1
    80003460:	c5d4                	sw	a3,12(a1)
    80003462:	e325                	bnez	a4,800034c2 <core_state_transition+0x146>
    80003464:	0027c703          	lbu	a4,2(a5)
    80003468:	00278693          	addi	a3,a5,2
    8000346c:	c375                	beqz	a4,80003550 <core_state_transition+0x1d4>
    8000346e:	0ec70d63          	beq	a4,a2,80003568 <core_state_transition+0x1ec>
    80003472:	4d90                	lw	a2,24(a1)
    80003474:	fd07071b          	addiw	a4,a4,-48
    80003478:	0ff77713          	zext.b	a4,a4
    8000347c:	2605                	addiw	a2,a2,1
    8000347e:	4825                	li	a6,9
    80003480:	cd90                	sw	a2,24(a1)
    80003482:	00e87863          	bgeu	a6,a4,80003492 <core_state_transition+0x116>
    80003486:	00378693          	addi	a3,a5,3
    8000348a:	4785                	li	a5,1
    8000348c:	e114                	sd	a3,0(a0)
    8000348e:	853e                	mv	a0,a5
    80003490:	8082                	ret
    80003492:	8636                	mv	a2,a3
    80003494:	0016c703          	lbu	a4,1(a3)
    80003498:	0685                	addi	a3,a3,1
    8000349a:	02c00893          	li	a7,44
    8000349e:	fd07079b          	addiw	a5,a4,-48
    800034a2:	0ff7f793          	zext.b	a5,a5
    800034a6:	cf45                	beqz	a4,8000355e <core_state_transition+0x1e2>
    800034a8:	0b170d63          	beq	a4,a7,80003562 <core_state_transition+0x1e6>
    800034ac:	fef873e3          	bgeu	a6,a5,80003492 <core_state_transition+0x116>
    800034b0:	41d8                	lw	a4,4(a1)
    800034b2:	00260693          	addi	a3,a2,2
    800034b6:	4785                	li	a5,1
    800034b8:	2705                	addiw	a4,a4,1
    800034ba:	c1d8                	sw	a4,4(a1)
    800034bc:	e114                	sd	a3,0(a0)
    800034be:	853e                	mv	a0,a5
    800034c0:	8082                	ret
    800034c2:	00278693          	addi	a3,a5,2
    800034c6:	4785                	li	a5,1
    800034c8:	b5f5                	j	800033b4 <core_state_transition+0x38>
    800034ca:	fd06869b          	addiw	a3,a3,-48
    800034ce:	0ff6f693          	zext.b	a3,a3
    800034d2:	4725                	li	a4,9
    800034d4:	f4d775e3          	bgeu	a4,a3,8000341e <core_state_transition+0xa2>
    800034d8:	49d8                	lw	a4,20(a1)
    800034da:	00178693          	addi	a3,a5,1
    800034de:	4785                	li	a5,1
    800034e0:	2705                	addiw	a4,a4,1
    800034e2:	c9d8                	sw	a4,20(a1)
    800034e4:	bdc1                	j	800033b4 <core_state_transition+0x38>
    800034e6:	4190                	lw	a2,0(a1)
    800034e8:	00168793          	addi	a5,a3,1
    800034ec:	2605                	addiw	a2,a2,1
    800034ee:	c190                	sw	a2,0(a1)
    800034f0:	0016c683          	lbu	a3,1(a3)
    800034f4:	fa9d                	bnez	a3,8000342a <core_state_transition+0xae>
    800034f6:	86be                	mv	a3,a5
    800034f8:	4795                	li	a5,5
    800034fa:	bd6d                	j	800033b4 <core_state_transition+0x38>
    800034fc:	4781                	li	a5,0
    800034fe:	0685                	addi	a3,a3,1
    80003500:	bd55                	j	800033b4 <core_state_transition+0x38>
    80003502:	4190                	lw	a2,0(a1)
    80003504:	00168793          	addi	a5,a3,1
    80003508:	2605                	addiw	a2,a2,1
    8000350a:	c190                	sw	a2,0(a1)
    8000350c:	0016c303          	lbu	t1,1(a3)
    80003510:	06030363          	beqz	t1,80003576 <core_state_transition+0x1fa>
    80003514:	04e30d63          	beq	t1,a4,8000356e <core_state_transition+0x1f2>
    80003518:	4590                	lw	a2,8(a1)
    8000351a:	fd03071b          	addiw	a4,t1,-48
    8000351e:	0ff77713          	zext.b	a4,a4
    80003522:	48a5                	li	a7,9
    80003524:	2605                	addiw	a2,a2,1
    80003526:	eee8f0e3          	bgeu	a7,a4,80003406 <core_state_transition+0x8a>
    8000352a:	01030663          	beq	t1,a6,80003536 <core_state_transition+0x1ba>
    8000352e:	c590                	sw	a2,8(a1)
    80003530:	0689                	addi	a3,a3,2
    80003532:	4785                	li	a5,1
    80003534:	b541                	j	800033b4 <core_state_transition+0x38>
    80003536:	c590                	sw	a2,8(a1)
    80003538:	b5dd                	j	8000341e <core_state_transition+0xa2>
    8000353a:	86be                	mv	a3,a5
    8000353c:	4791                	li	a5,4
    8000353e:	bd9d                	j	800033b4 <core_state_transition+0x38>
    80003540:	86be                	mv	a3,a5
    80003542:	0685                	addi	a3,a3,1
    80003544:	4795                	li	a5,5
    80003546:	b5bd                	j	800033b4 <core_state_transition+0x38>
    80003548:	86be                	mv	a3,a5
    8000354a:	0685                	addi	a3,a3,1
    8000354c:	4791                	li	a5,4
    8000354e:	b59d                	j	800033b4 <core_state_transition+0x38>
    80003550:	4799                	li	a5,6
    80003552:	b58d                	j	800033b4 <core_state_transition+0x38>
    80003554:	478d                	li	a5,3
    80003556:	bdb9                	j	800033b4 <core_state_transition+0x38>
    80003558:	478d                	li	a5,3
    8000355a:	0685                	addi	a3,a3,1
    8000355c:	bda1                	j	800033b4 <core_state_transition+0x38>
    8000355e:	479d                	li	a5,7
    80003560:	bd91                	j	800033b4 <core_state_transition+0x38>
    80003562:	479d                	li	a5,7
    80003564:	0685                	addi	a3,a3,1
    80003566:	b5b9                	j	800033b4 <core_state_transition+0x38>
    80003568:	4799                	li	a5,6
    8000356a:	0685                	addi	a3,a3,1
    8000356c:	b5a1                	j	800033b4 <core_state_transition+0x38>
    8000356e:	86be                	mv	a3,a5
    80003570:	0685                	addi	a3,a3,1
    80003572:	4789                	li	a5,2
    80003574:	b581                	j	800033b4 <core_state_transition+0x38>
    80003576:	86be                	mv	a3,a5
    80003578:	4789                	li	a5,2
    8000357a:	bd2d                	j	800033b4 <core_state_transition+0x38>

000000008000357c <core_bench_state>:
    8000357c:	7171                	addi	sp,sp,-176
    8000357e:	e54e                	sd	s3,136(sp)
    80003580:	e152                	sd	s4,128(sp)
    80003582:	01010993          	addi	s3,sp,16
    80003586:	03010a13          	addi	s4,sp,48
    8000358a:	f122                	sd	s0,160(sp)
    8000358c:	ed26                	sd	s1,152(sp)
    8000358e:	e94a                	sd	s2,144(sp)
    80003590:	fcd6                	sd	s5,120(sp)
    80003592:	f8da                	sd	s6,112(sp)
    80003594:	f0e2                	sd	s8,96(sp)
    80003596:	ece6                	sd	s9,88(sp)
    80003598:	84be                	mv	s1,a5
    8000359a:	8aba                	mv	s5,a4
    8000359c:	f506                	sd	ra,168(sp)
    8000359e:	f4de                	sd	s7,104(sp)
    800035a0:	842e                	mv	s0,a1
    800035a2:	e42e                	sd	a1,8(sp)
    800035a4:	8caa                	mv	s9,a0
    800035a6:	8c32                	mv	s8,a2
    800035a8:	8b36                	mv	s6,a3
    800035aa:	87d2                	mv	a5,s4
    800035ac:	894e                	mv	s2,s3
    800035ae:	874e                	mv	a4,s3
    800035b0:	0007a023          	sw	zero,0(a5)
    800035b4:	00072023          	sw	zero,0(a4)
    800035b8:	0791                	addi	a5,a5,4
    800035ba:	0894                	addi	a3,sp,80
    800035bc:	0711                	addi	a4,a4,4
    800035be:	fed799e3          	bne	a5,a3,800035b0 <core_bench_state+0x34>
    800035c2:	00044783          	lbu	a5,0(s0)
    800035c6:	00810b93          	addi	s7,sp,8
    800035ca:	c3e9                	beqz	a5,8000368c <core_bench_state+0x110>
    800035cc:	180c                	addi	a1,sp,48
    800035ce:	855e                	mv	a0,s7
    800035d0:	dadff0ef          	jal	8000337c <core_state_transition>
    800035d4:	2135473b          	sh2add.uw	a4,a0,s3
    800035d8:	66a2                	ld	a3,8(sp)
    800035da:	431c                	lw	a5,0(a4)
    800035dc:	0006c683          	lbu	a3,0(a3)
    800035e0:	2785                	addiw	a5,a5,1
    800035e2:	c31c                	sw	a5,0(a4)
    800035e4:	f6e5                	bnez	a3,800035cc <core_bench_state+0x50>
    800035e6:	e422                	sd	s0,8(sp)
    800035e8:	088c8cbb          	add.uw	s9,s9,s0
    800035ec:	03947563          	bgeu	s0,s9,80003616 <core_bench_state+0x9a>
    800035f0:	87a2                	mv	a5,s0
    800035f2:	02c00613          	li	a2,44
    800035f6:	0007c703          	lbu	a4,0(a5)
    800035fa:	018746b3          	xor	a3,a4,s8
    800035fe:	00c70463          	beq	a4,a2,80003606 <core_bench_state+0x8a>
    80003602:	00d78023          	sb	a3,0(a5)
    80003606:	97d6                	add	a5,a5,s5
    80003608:	ff97e7e3          	bltu	a5,s9,800035f6 <core_bench_state+0x7a>
    8000360c:	00044783          	lbu	a5,0(s0)
    80003610:	00810b93          	addi	s7,sp,8
    80003614:	cf91                	beqz	a5,80003630 <core_bench_state+0xb4>
    80003616:	180c                	addi	a1,sp,48
    80003618:	855e                	mv	a0,s7
    8000361a:	d63ff0ef          	jal	8000337c <core_state_transition>
    8000361e:	2135473b          	sh2add.uw	a4,a0,s3
    80003622:	66a2                	ld	a3,8(sp)
    80003624:	431c                	lw	a5,0(a4)
    80003626:	0006c683          	lbu	a3,0(a3)
    8000362a:	2785                	addiw	a5,a5,1
    8000362c:	c31c                	sw	a5,0(a4)
    8000362e:	f6e5                	bnez	a3,80003616 <core_bench_state+0x9a>
    80003630:	8722                	mv	a4,s0
    80003632:	02c00613          	li	a2,44
    80003636:	01947d63          	bgeu	s0,s9,80003650 <core_bench_state+0xd4>
    8000363a:	00074783          	lbu	a5,0(a4)
    8000363e:	0167c6b3          	xor	a3,a5,s6
    80003642:	00c78463          	beq	a5,a2,8000364a <core_bench_state+0xce>
    80003646:	00d70023          	sb	a3,0(a4)
    8000364a:	9756                	add	a4,a4,s5
    8000364c:	ff9767e3          	bltu	a4,s9,8000363a <core_bench_state+0xbe>
    80003650:	02098993          	addi	s3,s3,32 # 1020 <_start-0x7fffefe0>
    80003654:	00092503          	lw	a0,0(s2) # fffffffffffff000 <__bss_end+0xffffffff7fffa850>
    80003658:	85a6                	mv	a1,s1
    8000365a:	0911                	addi	s2,s2,4
    8000365c:	368000ef          	jal	800039c4 <crcu32>
    80003660:	85aa                	mv	a1,a0
    80003662:	000a2503          	lw	a0,0(s4)
    80003666:	0a11                	addi	s4,s4,4
    80003668:	35c000ef          	jal	800039c4 <crcu32>
    8000366c:	84aa                	mv	s1,a0
    8000366e:	ff3913e3          	bne	s2,s3,80003654 <core_bench_state+0xd8>
    80003672:	70aa                	ld	ra,168(sp)
    80003674:	740a                	ld	s0,160(sp)
    80003676:	64ea                	ld	s1,152(sp)
    80003678:	694a                	ld	s2,144(sp)
    8000367a:	69aa                	ld	s3,136(sp)
    8000367c:	6a0a                	ld	s4,128(sp)
    8000367e:	7ae6                	ld	s5,120(sp)
    80003680:	7b46                	ld	s6,112(sp)
    80003682:	7ba6                	ld	s7,104(sp)
    80003684:	7c06                	ld	s8,96(sp)
    80003686:	6ce6                	ld	s9,88(sp)
    80003688:	614d                	addi	sp,sp,176
    8000368a:	8082                	ret
    8000368c:	088c8cbb          	add.uw	s9,s9,s0
    80003690:	f79460e3          	bltu	s0,s9,800035f0 <core_bench_state+0x74>
    80003694:	bf75                	j	80003650 <core_bench_state+0xd4>

0000000080003696 <get_seed_32>:
    80003696:	4795                	li	a5,5
    80003698:	04a7e463          	bltu	a5,a0,800036e0 <get_seed_32+0x4a>
    8000369c:	00001717          	auipc	a4,0x1
    800036a0:	ebc70713          	addi	a4,a4,-324 # 80004558 <errpat+0x20>
    800036a4:	20e54533          	sh2add	a0,a0,a4
    800036a8:	411c                	lw	a5,0(a0)
    800036aa:	97ba                	add	a5,a5,a4
    800036ac:	8782                	jr	a5
    800036ae:	00001517          	auipc	a0,0x1
    800036b2:	0ee52503          	lw	a0,238(a0) # 8000479c <seed5_volatile>
    800036b6:	8082                	ret
    800036b8:	00001517          	auipc	a0,0x1
    800036bc:	0ec52503          	lw	a0,236(a0) # 800047a4 <seed1_volatile>
    800036c0:	8082                	ret
    800036c2:	00001517          	auipc	a0,0x1
    800036c6:	0de52503          	lw	a0,222(a0) # 800047a0 <seed2_volatile>
    800036ca:	8082                	ret
    800036cc:	00001517          	auipc	a0,0x1
    800036d0:	0c452503          	lw	a0,196(a0) # 80004790 <seed3_volatile>
    800036d4:	8082                	ret
    800036d6:	00001517          	auipc	a0,0x1
    800036da:	0b652503          	lw	a0,182(a0) # 8000478c <seed4_volatile>
    800036de:	8082                	ret
    800036e0:	4501                	li	a0,0
    800036e2:	8082                	ret

00000000800036e4 <crcu8>:
    800036e4:	0ff5f793          	zext.b	a5,a1
    800036e8:	07a2                	slli	a5,a5,0x8
    800036ea:	81a1                	srli	a1,a1,0x8
    800036ec:	00b7e733          	or	a4,a5,a1
    800036f0:	737d                	lui	t1,0xfffff
    800036f2:	6785                	lui	a5,0x1
    800036f4:	f0f78793          	addi	a5,a5,-241 # f0f <_start-0x7ffff0f1>
    800036f8:	0f030313          	addi	t1,t1,240 # fffffffffffff0f0 <__bss_end+0xffffffff7fffa940>
    800036fc:	00f776b3          	and	a3,a4,a5
    80003700:	00677733          	and	a4,a4,t1
    80003704:	0047571b          	srliw	a4,a4,0x4
    80003708:	0046969b          	slliw	a3,a3,0x4
    8000370c:	8ed9                	or	a3,a3,a4
    8000370e:	78f5                	lui	a7,0xffffd
    80003710:	670d                	lui	a4,0x3
    80003712:	33370713          	addi	a4,a4,819 # 3333 <_start-0x7fffcccd>
    80003716:	ccc88893          	addi	a7,a7,-820 # ffffffffffffcccc <__bss_end+0xffffffff7fff851c>
    8000371a:	00f57613          	andi	a2,a0,15
    8000371e:	00e6f5b3          	and	a1,a3,a4
    80003722:	8111                	srli	a0,a0,0x4
    80003724:	0116f6b3          	and	a3,a3,a7
    80003728:	0046161b          	slliw	a2,a2,0x4
    8000372c:	8e49                	or	a2,a2,a0
    8000372e:	0026d69b          	srliw	a3,a3,0x2
    80003732:	0025959b          	slliw	a1,a1,0x2
    80003736:	8dd5                	or	a1,a1,a3
    80003738:	6515                	lui	a0,0x5
    8000373a:	03367693          	andi	a3,a2,51
    8000373e:	786d                	lui	a6,0xffffb
    80003740:	0cc67613          	andi	a2,a2,204
    80003744:	aaa80813          	addi	a6,a6,-1366 # ffffffffffffaaaa <__bss_end+0xffffffff7fff62fa>
    80003748:	00265e1b          	srliw	t3,a2,0x2
    8000374c:	55550513          	addi	a0,a0,1365 # 5555 <_start-0x7fffaaab>
    80003750:	0026969b          	slliw	a3,a3,0x2
    80003754:	00a5f633          	and	a2,a1,a0
    80003758:	01c6e6b3          	or	a3,a3,t3
    8000375c:	0105f5b3          	and	a1,a1,a6
    80003760:	0015d59b          	srliw	a1,a1,0x1
    80003764:	0016161b          	slliw	a2,a2,0x1
    80003768:	0556fe93          	andi	t4,a3,85
    8000376c:	0aa6f693          	andi	a3,a3,170
    80003770:	00b66e33          	or	t3,a2,a1
    80003774:	001e9e9b          	slliw	t4,t4,0x1
    80003778:	0016d69b          	srliw	a3,a3,0x1
    8000377c:	008e5e1b          	srliw	t3,t3,0x8
    80003780:	00dee6b3          	or	a3,t4,a3
    80003784:	00de46b3          	xor	a3,t3,a3
    80003788:	00001e17          	auipc	t3,0x1
    8000378c:	de8e0e13          	addi	t3,t3,-536 # 80004570 <errpat+0x38>
    80003790:	21c6a6b3          	sh1add	a3,a3,t3
    80003794:	0006d683          	lhu	a3,0(a3)
    80003798:	8e4d                	or	a2,a2,a1
    8000379a:	0086161b          	slliw	a2,a2,0x8
    8000379e:	8e35                	xor	a2,a2,a3
    800037a0:	03061593          	slli	a1,a2,0x30
    800037a4:	0ff6f693          	zext.b	a3,a3
    800037a8:	0385d613          	srli	a2,a1,0x38
    800037ac:	06a2                	slli	a3,a3,0x8
    800037ae:	8e55                	or	a2,a2,a3
    800037b0:	00f676b3          	and	a3,a2,a5
    800037b4:	00667633          	and	a2,a2,t1
    800037b8:	0046561b          	srliw	a2,a2,0x4
    800037bc:	0046969b          	slliw	a3,a3,0x4
    800037c0:	8ed1                	or	a3,a3,a2
    800037c2:	00e6f7b3          	and	a5,a3,a4
    800037c6:	0116f6b3          	and	a3,a3,a7
    800037ca:	0026d69b          	srliw	a3,a3,0x2
    800037ce:	0027979b          	slliw	a5,a5,0x2
    800037d2:	8fd5                	or	a5,a5,a3
    800037d4:	8d7d                	and	a0,a0,a5
    800037d6:	0107f7b3          	and	a5,a5,a6
    800037da:	0017d79b          	srliw	a5,a5,0x1
    800037de:	0015151b          	slliw	a0,a0,0x1
    800037e2:	8d5d                	or	a0,a0,a5
    800037e4:	8082                	ret

00000000800037e6 <crcu16>:
    800037e6:	0ff5f793          	zext.b	a5,a1
    800037ea:	07a2                	slli	a5,a5,0x8
    800037ec:	81a1                	srli	a1,a1,0x8
    800037ee:	6705                	lui	a4,0x1
    800037f0:	737d                	lui	t1,0xfffff
    800037f2:	0f030313          	addi	t1,t1,240 # fffffffffffff0f0 <__bss_end+0xffffffff7fffa940>
    800037f6:	f0f70713          	addi	a4,a4,-241 # f0f <_start-0x7ffff0f1>
    800037fa:	8fcd                	or	a5,a5,a1
    800037fc:	00e7f5b3          	and	a1,a5,a4
    80003800:	0067f7b3          	and	a5,a5,t1
    80003804:	0047d79b          	srliw	a5,a5,0x4
    80003808:	0045959b          	slliw	a1,a1,0x4
    8000380c:	8ddd                	or	a1,a1,a5
    8000380e:	78f5                	lui	a7,0xffffd
    80003810:	678d                	lui	a5,0x3
    80003812:	ccc88893          	addi	a7,a7,-820 # ffffffffffffcccc <__bss_end+0xffffffff7fff851c>
    80003816:	33378793          	addi	a5,a5,819 # 3333 <_start-0x7fffcccd>
    8000381a:	00f57693          	andi	a3,a0,15
    8000381e:	0f057813          	andi	a6,a0,240
    80003822:	00f5f633          	and	a2,a1,a5
    80003826:	0048581b          	srliw	a6,a6,0x4
    8000382a:	0115f5b3          	and	a1,a1,a7
    8000382e:	0046969b          	slliw	a3,a3,0x4
    80003832:	0106e6b3          	or	a3,a3,a6
    80003836:	0025d59b          	srliw	a1,a1,0x2
    8000383a:	0026161b          	slliw	a2,a2,0x2
    8000383e:	8e4d                	or	a2,a2,a1
    80003840:	0336fe13          	andi	t3,a3,51
    80003844:	6595                	lui	a1,0x5
    80003846:	0cc6f693          	andi	a3,a3,204
    8000384a:	786d                	lui	a6,0xffffb
    8000384c:	55558593          	addi	a1,a1,1365 # 5555 <_start-0x7fffaaab>
    80003850:	aaa80813          	addi	a6,a6,-1366 # ffffffffffffaaaa <__bss_end+0xffffffff7fff62fa>
    80003854:	0026de9b          	srliw	t4,a3,0x2
    80003858:	002e1e1b          	slliw	t3,t3,0x2
    8000385c:	00b676b3          	and	a3,a2,a1
    80003860:	01de6e33          	or	t3,t3,t4
    80003864:	01067633          	and	a2,a2,a6
    80003868:	0016969b          	slliw	a3,a3,0x1
    8000386c:	0016561b          	srliw	a2,a2,0x1
    80003870:	055e7f13          	andi	t5,t3,85
    80003874:	0aae7e13          	andi	t3,t3,170
    80003878:	00c6eeb3          	or	t4,a3,a2
    8000387c:	001f1f1b          	slliw	t5,t5,0x1
    80003880:	001e5e1b          	srliw	t3,t3,0x1
    80003884:	01cf6e33          	or	t3,t5,t3
    80003888:	008ede9b          	srliw	t4,t4,0x8
    8000388c:	01ceceb3          	xor	t4,t4,t3
    80003890:	00001e17          	auipc	t3,0x1
    80003894:	ce0e0e13          	addi	t3,t3,-800 # 80004570 <errpat+0x38>
    80003898:	8e55                	or	a2,a2,a3
    8000389a:	21cea6b3          	sh1add	a3,t4,t3
    8000389e:	0006d683          	lhu	a3,0(a3)
    800038a2:	0086161b          	slliw	a2,a2,0x8
    800038a6:	0085551b          	srliw	a0,a0,0x8
    800038aa:	8e35                	xor	a2,a2,a3
    800038ac:	03061e93          	slli	t4,a2,0x30
    800038b0:	0ff6f693          	zext.b	a3,a3
    800038b4:	038ed613          	srli	a2,t4,0x38
    800038b8:	06a2                	slli	a3,a3,0x8
    800038ba:	8ed1                	or	a3,a3,a2
    800038bc:	00e6f633          	and	a2,a3,a4
    800038c0:	0066f6b3          	and	a3,a3,t1
    800038c4:	0046d69b          	srliw	a3,a3,0x4
    800038c8:	0046161b          	slliw	a2,a2,0x4
    800038cc:	8e55                	or	a2,a2,a3
    800038ce:	00f676b3          	and	a3,a2,a5
    800038d2:	01167633          	and	a2,a2,a7
    800038d6:	0026561b          	srliw	a2,a2,0x2
    800038da:	0026969b          	slliw	a3,a3,0x2
    800038de:	8ed1                	or	a3,a3,a2
    800038e0:	00b6f633          	and	a2,a3,a1
    800038e4:	0106f6b3          	and	a3,a3,a6
    800038e8:	0016d69b          	srliw	a3,a3,0x1
    800038ec:	0016161b          	slliw	a2,a2,0x1
    800038f0:	8e55                	or	a2,a2,a3
    800038f2:	0ff67693          	zext.b	a3,a2
    800038f6:	06a2                	slli	a3,a3,0x8
    800038f8:	8221                	srli	a2,a2,0x8
    800038fa:	8e55                	or	a2,a2,a3
    800038fc:	00e676b3          	and	a3,a2,a4
    80003900:	00667eb3          	and	t4,a2,t1
    80003904:	004ede9b          	srliw	t4,t4,0x4
    80003908:	00f57613          	andi	a2,a0,15
    8000390c:	0046969b          	slliw	a3,a3,0x4
    80003910:	01d6e6b3          	or	a3,a3,t4
    80003914:	8111                	srli	a0,a0,0x4
    80003916:	0046161b          	slliw	a2,a2,0x4
    8000391a:	8e49                	or	a2,a2,a0
    8000391c:	0116feb3          	and	t4,a3,a7
    80003920:	00f6f533          	and	a0,a3,a5
    80003924:	002ede9b          	srliw	t4,t4,0x2
    80003928:	03367693          	andi	a3,a2,51
    8000392c:	0025151b          	slliw	a0,a0,0x2
    80003930:	0cc67613          	andi	a2,a2,204
    80003934:	01d56533          	or	a0,a0,t4
    80003938:	0026561b          	srliw	a2,a2,0x2
    8000393c:	0026969b          	slliw	a3,a3,0x2
    80003940:	8ed1                	or	a3,a3,a2
    80003942:	00b57633          	and	a2,a0,a1
    80003946:	01057533          	and	a0,a0,a6
    8000394a:	0556ff13          	andi	t5,a3,85
    8000394e:	0016161b          	slliw	a2,a2,0x1
    80003952:	0015551b          	srliw	a0,a0,0x1
    80003956:	0aa6f693          	andi	a3,a3,170
    8000395a:	00a66eb3          	or	t4,a2,a0
    8000395e:	0016d69b          	srliw	a3,a3,0x1
    80003962:	001f1f1b          	slliw	t5,t5,0x1
    80003966:	00df6f33          	or	t5,t5,a3
    8000396a:	008ed69b          	srliw	a3,t4,0x8
    8000396e:	01e6c6b3          	xor	a3,a3,t5
    80003972:	21c6a6b3          	sh1add	a3,a3,t3
    80003976:	0006d683          	lhu	a3,0(a3)
    8000397a:	008e961b          	slliw	a2,t4,0x8
    8000397e:	8e35                	xor	a2,a2,a3
    80003980:	03061513          	slli	a0,a2,0x30
    80003984:	0ff6f693          	zext.b	a3,a3
    80003988:	03855613          	srli	a2,a0,0x38
    8000398c:	06a2                	slli	a3,a3,0x8
    8000398e:	8ed1                	or	a3,a3,a2
    80003990:	8f75                	and	a4,a4,a3
    80003992:	0066f6b3          	and	a3,a3,t1
    80003996:	0046d69b          	srliw	a3,a3,0x4
    8000399a:	0047171b          	slliw	a4,a4,0x4
    8000399e:	8f55                	or	a4,a4,a3
    800039a0:	8ff9                	and	a5,a5,a4
    800039a2:	01177733          	and	a4,a4,a7
    800039a6:	0027571b          	srliw	a4,a4,0x2
    800039aa:	0027979b          	slliw	a5,a5,0x2
    800039ae:	8fd9                	or	a5,a5,a4
    800039b0:	00b7f533          	and	a0,a5,a1
    800039b4:	0107f7b3          	and	a5,a5,a6
    800039b8:	0017d79b          	srliw	a5,a5,0x1
    800039bc:	0015151b          	slliw	a0,a0,0x1
    800039c0:	8d5d                	or	a0,a0,a5
    800039c2:	8082                	ret

00000000800039c4 <crcu32>:
    800039c4:	0ff5f793          	zext.b	a5,a1
    800039c8:	07a2                	slli	a5,a5,0x8
    800039ca:	81a1                	srli	a1,a1,0x8
    800039cc:	6705                	lui	a4,0x1
    800039ce:	78fd                	lui	a7,0xfffff
    800039d0:	0f088893          	addi	a7,a7,240 # fffffffffffff0f0 <__bss_end+0xffffffff7fffa940>
    800039d4:	f0f70713          	addi	a4,a4,-241 # f0f <_start-0x7ffff0f1>
    800039d8:	8fcd                	or	a5,a5,a1
    800039da:	00e7f6b3          	and	a3,a5,a4
    800039de:	0117f7b3          	and	a5,a5,a7
    800039e2:	0047d79b          	srliw	a5,a5,0x4
    800039e6:	0046969b          	slliw	a3,a3,0x4
    800039ea:	8edd                	or	a3,a3,a5
    800039ec:	7875                	lui	a6,0xffffd
    800039ee:	678d                	lui	a5,0x3
    800039f0:	ccc80813          	addi	a6,a6,-820 # ffffffffffffcccc <__bss_end+0xffffffff7fff851c>
    800039f4:	33378793          	addi	a5,a5,819 # 3333 <_start-0x7fffcccd>
    800039f8:	00f57613          	andi	a2,a0,15
    800039fc:	0f057593          	andi	a1,a0,240
    80003a00:	00f6f333          	and	t1,a3,a5
    80003a04:	0045d59b          	srliw	a1,a1,0x4
    80003a08:	0106f6b3          	and	a3,a3,a6
    80003a0c:	0046161b          	slliw	a2,a2,0x4
    80003a10:	8e4d                	or	a2,a2,a1
    80003a12:	0026d69b          	srliw	a3,a3,0x2
    80003a16:	0023131b          	slliw	t1,t1,0x2
    80003a1a:	00d36333          	or	t1,t1,a3
    80003a1e:	03367e13          	andi	t3,a2,51
    80003a22:	6695                	lui	a3,0x5
    80003a24:	0cc67613          	andi	a2,a2,204
    80003a28:	75ed                	lui	a1,0xffffb
    80003a2a:	55568693          	addi	a3,a3,1365 # 5555 <_start-0x7fffaaab>
    80003a2e:	aaa58593          	addi	a1,a1,-1366 # ffffffffffffaaaa <__bss_end+0xffffffff7fff62fa>
    80003a32:	00265e9b          	srliw	t4,a2,0x2
    80003a36:	002e1e1b          	slliw	t3,t3,0x2
    80003a3a:	00d37633          	and	a2,t1,a3
    80003a3e:	01de6e33          	or	t3,t3,t4
    80003a42:	00b37333          	and	t1,t1,a1
    80003a46:	0016161b          	slliw	a2,a2,0x1
    80003a4a:	0013531b          	srliw	t1,t1,0x1
    80003a4e:	055e7f13          	andi	t5,t3,85
    80003a52:	0aae7e13          	andi	t3,t3,170
    80003a56:	00666eb3          	or	t4,a2,t1
    80003a5a:	001f1f1b          	slliw	t5,t5,0x1
    80003a5e:	001e5e1b          	srliw	t3,t3,0x1
    80003a62:	01cf6e33          	or	t3,t5,t3
    80003a66:	008ede9b          	srliw	t4,t4,0x8
    80003a6a:	01ceceb3          	xor	t4,t4,t3
    80003a6e:	00001e17          	auipc	t3,0x1
    80003a72:	b02e0e13          	addi	t3,t3,-1278 # 80004570 <errpat+0x38>
    80003a76:	00666333          	or	t1,a2,t1
    80003a7a:	21cea633          	sh1add	a2,t4,t3
    80003a7e:	00065603          	lhu	a2,0(a2)
    80003a82:	0083131b          	slliw	t1,t1,0x8
    80003a86:	00855f1b          	srliw	t5,a0,0x8
    80003a8a:	00664333          	xor	t1,a2,t1
    80003a8e:	03031e93          	slli	t4,t1,0x30
    80003a92:	0ff67613          	zext.b	a2,a2
    80003a96:	038ed313          	srli	t1,t4,0x38
    80003a9a:	0622                	slli	a2,a2,0x8
    80003a9c:	00666633          	or	a2,a2,t1
    80003aa0:	00e67333          	and	t1,a2,a4
    80003aa4:	01167633          	and	a2,a2,a7
    80003aa8:	0046561b          	srliw	a2,a2,0x4
    80003aac:	0043131b          	slliw	t1,t1,0x4
    80003ab0:	00c36333          	or	t1,t1,a2
    80003ab4:	00f37633          	and	a2,t1,a5
    80003ab8:	01037333          	and	t1,t1,a6
    80003abc:	0023531b          	srliw	t1,t1,0x2
    80003ac0:	0026161b          	slliw	a2,a2,0x2
    80003ac4:	00666633          	or	a2,a2,t1
    80003ac8:	00d67333          	and	t1,a2,a3
    80003acc:	8e6d                	and	a2,a2,a1
    80003ace:	0016561b          	srliw	a2,a2,0x1
    80003ad2:	0013131b          	slliw	t1,t1,0x1
    80003ad6:	00c36333          	or	t1,t1,a2
    80003ada:	0ff37613          	zext.b	a2,t1
    80003ade:	0622                	slli	a2,a2,0x8
    80003ae0:	00835313          	srli	t1,t1,0x8
    80003ae4:	00666633          	or	a2,a2,t1
    80003ae8:	00e67eb3          	and	t4,a2,a4
    80003aec:	01167633          	and	a2,a2,a7
    80003af0:	0046561b          	srliw	a2,a2,0x4
    80003af4:	004e9e9b          	slliw	t4,t4,0x4
    80003af8:	00ceeeb3          	or	t4,t4,a2
    80003afc:	00ff7613          	andi	a2,t5,15
    80003b00:	0f0f7f13          	andi	t5,t5,240
    80003b04:	00fef333          	and	t1,t4,a5
    80003b08:	004f5f1b          	srliw	t5,t5,0x4
    80003b0c:	010efeb3          	and	t4,t4,a6
    80003b10:	0046161b          	slliw	a2,a2,0x4
    80003b14:	01e66633          	or	a2,a2,t5
    80003b18:	002ede9b          	srliw	t4,t4,0x2
    80003b1c:	0023131b          	slliw	t1,t1,0x2
    80003b20:	01d36333          	or	t1,t1,t4
    80003b24:	03367e93          	andi	t4,a2,51
    80003b28:	0cc67613          	andi	a2,a2,204
    80003b2c:	00265f1b          	srliw	t5,a2,0x2
    80003b30:	002e9e9b          	slliw	t4,t4,0x2
    80003b34:	00d37633          	and	a2,t1,a3
    80003b38:	01eeeeb3          	or	t4,t4,t5
    80003b3c:	00b37333          	and	t1,t1,a1
    80003b40:	0016161b          	slliw	a2,a2,0x1
    80003b44:	0013531b          	srliw	t1,t1,0x1
    80003b48:	055eff93          	andi	t6,t4,85
    80003b4c:	0aaefe93          	andi	t4,t4,170
    80003b50:	00666f33          	or	t5,a2,t1
    80003b54:	001f9f9b          	slliw	t6,t6,0x1
    80003b58:	001ede9b          	srliw	t4,t4,0x1
    80003b5c:	008f5f1b          	srliw	t5,t5,0x8
    80003b60:	01dfeeb3          	or	t4,t6,t4
    80003b64:	01df4eb3          	xor	t4,t5,t4
    80003b68:	00666333          	or	t1,a2,t1
    80003b6c:	21cea633          	sh1add	a2,t4,t3
    80003b70:	00065603          	lhu	a2,0(a2)
    80003b74:	0083131b          	slliw	t1,t1,0x8
    80003b78:	0105551b          	srliw	a0,a0,0x10
    80003b7c:	00664333          	xor	t1,a2,t1
    80003b80:	03031e93          	slli	t4,t1,0x30
    80003b84:	0ff67613          	zext.b	a2,a2
    80003b88:	038ed313          	srli	t1,t4,0x38
    80003b8c:	0622                	slli	a2,a2,0x8
    80003b8e:	00666633          	or	a2,a2,t1
    80003b92:	00e67333          	and	t1,a2,a4
    80003b96:	01167633          	and	a2,a2,a7
    80003b9a:	0046561b          	srliw	a2,a2,0x4
    80003b9e:	0043131b          	slliw	t1,t1,0x4
    80003ba2:	00c36333          	or	t1,t1,a2
    80003ba6:	00f37633          	and	a2,t1,a5
    80003baa:	01037333          	and	t1,t1,a6
    80003bae:	0023531b          	srliw	t1,t1,0x2
    80003bb2:	0026161b          	slliw	a2,a2,0x2
    80003bb6:	00666633          	or	a2,a2,t1
    80003bba:	00d67333          	and	t1,a2,a3
    80003bbe:	8e6d                	and	a2,a2,a1
    80003bc0:	0016561b          	srliw	a2,a2,0x1
    80003bc4:	0013131b          	slliw	t1,t1,0x1
    80003bc8:	00c36333          	or	t1,t1,a2
    80003bcc:	0ff37613          	zext.b	a2,t1
    80003bd0:	0622                	slli	a2,a2,0x8
    80003bd2:	00835313          	srli	t1,t1,0x8
    80003bd6:	00666333          	or	t1,a2,t1
    80003bda:	00e37633          	and	a2,t1,a4
    80003bde:	01137333          	and	t1,t1,a7
    80003be2:	0043531b          	srliw	t1,t1,0x4
    80003be6:	0046161b          	slliw	a2,a2,0x4
    80003bea:	00666633          	or	a2,a2,t1
    80003bee:	0f057f13          	andi	t5,a0,240
    80003bf2:	00f57313          	andi	t1,a0,15
    80003bf6:	00f67eb3          	and	t4,a2,a5
    80003bfa:	004f5f1b          	srliw	t5,t5,0x4
    80003bfe:	01067633          	and	a2,a2,a6
    80003c02:	0043131b          	slliw	t1,t1,0x4
    80003c06:	01e36333          	or	t1,t1,t5
    80003c0a:	0026561b          	srliw	a2,a2,0x2
    80003c0e:	002e9e9b          	slliw	t4,t4,0x2
    80003c12:	00ceeeb3          	or	t4,t4,a2
    80003c16:	03337613          	andi	a2,t1,51
    80003c1a:	0cc37313          	andi	t1,t1,204
    80003c1e:	00235f1b          	srliw	t5,t1,0x2
    80003c22:	0026161b          	slliw	a2,a2,0x2
    80003c26:	00def333          	and	t1,t4,a3
    80003c2a:	01e66633          	or	a2,a2,t5
    80003c2e:	00befeb3          	and	t4,t4,a1
    80003c32:	001ede9b          	srliw	t4,t4,0x1
    80003c36:	0013131b          	slliw	t1,t1,0x1
    80003c3a:	05567f93          	andi	t6,a2,85
    80003c3e:	0aa67613          	andi	a2,a2,170
    80003c42:	01d36f33          	or	t5,t1,t4
    80003c46:	001f9f9b          	slliw	t6,t6,0x1
    80003c4a:	0016561b          	srliw	a2,a2,0x1
    80003c4e:	008f5f1b          	srliw	t5,t5,0x8
    80003c52:	00cfe633          	or	a2,t6,a2
    80003c56:	00cf4633          	xor	a2,t5,a2
    80003c5a:	21c62633          	sh1add	a2,a2,t3
    80003c5e:	00065603          	lhu	a2,0(a2)
    80003c62:	01d36333          	or	t1,t1,t4
    80003c66:	0083131b          	slliw	t1,t1,0x8
    80003c6a:	00664333          	xor	t1,a2,t1
    80003c6e:	03031e93          	slli	t4,t1,0x30
    80003c72:	0ff67613          	zext.b	a2,a2
    80003c76:	038ed313          	srli	t1,t4,0x38
    80003c7a:	0622                	slli	a2,a2,0x8
    80003c7c:	00666633          	or	a2,a2,t1
    80003c80:	00e67333          	and	t1,a2,a4
    80003c84:	01167633          	and	a2,a2,a7
    80003c88:	0046561b          	srliw	a2,a2,0x4
    80003c8c:	0043131b          	slliw	t1,t1,0x4
    80003c90:	00c36333          	or	t1,t1,a2
    80003c94:	00f37633          	and	a2,t1,a5
    80003c98:	01037333          	and	t1,t1,a6
    80003c9c:	0023531b          	srliw	t1,t1,0x2
    80003ca0:	0026161b          	slliw	a2,a2,0x2
    80003ca4:	00666633          	or	a2,a2,t1
    80003ca8:	00d67333          	and	t1,a2,a3
    80003cac:	8e6d                	and	a2,a2,a1
    80003cae:	0016561b          	srliw	a2,a2,0x1
    80003cb2:	0013131b          	slliw	t1,t1,0x1
    80003cb6:	00c36333          	or	t1,t1,a2
    80003cba:	0ff37613          	zext.b	a2,t1
    80003cbe:	0622                	slli	a2,a2,0x8
    80003cc0:	00835313          	srli	t1,t1,0x8
    80003cc4:	00666633          	or	a2,a2,t1
    80003cc8:	00e67eb3          	and	t4,a2,a4
    80003ccc:	01167333          	and	t1,a2,a7
    80003cd0:	8121                	srli	a0,a0,0x8
    80003cd2:	00f57613          	andi	a2,a0,15
    80003cd6:	0043531b          	srliw	t1,t1,0x4
    80003cda:	004e9e9b          	slliw	t4,t4,0x4
    80003cde:	0046161b          	slliw	a2,a2,0x4
    80003ce2:	006eeeb3          	or	t4,t4,t1
    80003ce6:	8111                	srli	a0,a0,0x4
    80003ce8:	00fef333          	and	t1,t4,a5
    80003cec:	8d51                	or	a0,a0,a2
    80003cee:	010efeb3          	and	t4,t4,a6
    80003cf2:	03357613          	andi	a2,a0,51
    80003cf6:	002ede9b          	srliw	t4,t4,0x2
    80003cfa:	0cc57513          	andi	a0,a0,204
    80003cfe:	0023131b          	slliw	t1,t1,0x2
    80003d02:	01d36333          	or	t1,t1,t4
    80003d06:	0025551b          	srliw	a0,a0,0x2
    80003d0a:	0026161b          	slliw	a2,a2,0x2
    80003d0e:	8e49                	or	a2,a2,a0
    80003d10:	00d37533          	and	a0,t1,a3
    80003d14:	00b37333          	and	t1,t1,a1
    80003d18:	05567f13          	andi	t5,a2,85
    80003d1c:	0015151b          	slliw	a0,a0,0x1
    80003d20:	0013531b          	srliw	t1,t1,0x1
    80003d24:	0aa67613          	andi	a2,a2,170
    80003d28:	00656eb3          	or	t4,a0,t1
    80003d2c:	0016561b          	srliw	a2,a2,0x1
    80003d30:	001f1f1b          	slliw	t5,t5,0x1
    80003d34:	00cf6f33          	or	t5,t5,a2
    80003d38:	008ed61b          	srliw	a2,t4,0x8
    80003d3c:	01e64633          	xor	a2,a2,t5
    80003d40:	21c62633          	sh1add	a2,a2,t3
    80003d44:	00065603          	lhu	a2,0(a2)
    80003d48:	008e951b          	slliw	a0,t4,0x8
    80003d4c:	8d31                	xor	a0,a0,a2
    80003d4e:	03051313          	slli	t1,a0,0x30
    80003d52:	0ff67613          	zext.b	a2,a2
    80003d56:	03835513          	srli	a0,t1,0x38
    80003d5a:	0622                	slli	a2,a2,0x8
    80003d5c:	8e49                	or	a2,a2,a0
    80003d5e:	8f71                	and	a4,a4,a2
    80003d60:	01167633          	and	a2,a2,a7
    80003d64:	0046561b          	srliw	a2,a2,0x4
    80003d68:	0047171b          	slliw	a4,a4,0x4
    80003d6c:	8f51                	or	a4,a4,a2
    80003d6e:	8ff9                	and	a5,a5,a4
    80003d70:	01077733          	and	a4,a4,a6
    80003d74:	0027571b          	srliw	a4,a4,0x2
    80003d78:	0027979b          	slliw	a5,a5,0x2
    80003d7c:	8fd9                	or	a5,a5,a4
    80003d7e:	00d7f533          	and	a0,a5,a3
    80003d82:	8fed                	and	a5,a5,a1
    80003d84:	0017d79b          	srliw	a5,a5,0x1
    80003d88:	0015151b          	slliw	a0,a0,0x1
    80003d8c:	8d5d                	or	a0,a0,a5
    80003d8e:	8082                	ret

0000000080003d90 <crc16>:
    80003d90:	0ff5f793          	zext.b	a5,a1
    80003d94:	07a2                	slli	a5,a5,0x8
    80003d96:	81a1                	srli	a1,a1,0x8
    80003d98:	6705                	lui	a4,0x1
    80003d9a:	737d                	lui	t1,0xfffff
    80003d9c:	0f030313          	addi	t1,t1,240 # fffffffffffff0f0 <__bss_end+0xffffffff7fffa940>
    80003da0:	f0f70713          	addi	a4,a4,-241 # f0f <_start-0x7ffff0f1>
    80003da4:	8fcd                	or	a5,a5,a1
    80003da6:	00e7f5b3          	and	a1,a5,a4
    80003daa:	0067f7b3          	and	a5,a5,t1
    80003dae:	0047d79b          	srliw	a5,a5,0x4
    80003db2:	0045959b          	slliw	a1,a1,0x4
    80003db6:	8ddd                	or	a1,a1,a5
    80003db8:	78f5                	lui	a7,0xffffd
    80003dba:	678d                	lui	a5,0x3
    80003dbc:	ccc88893          	addi	a7,a7,-820 # ffffffffffffcccc <__bss_end+0xffffffff7fff851c>
    80003dc0:	33378793          	addi	a5,a5,819 # 3333 <_start-0x7fffcccd>
    80003dc4:	00f57693          	andi	a3,a0,15
    80003dc8:	0f057813          	andi	a6,a0,240
    80003dcc:	00f5f633          	and	a2,a1,a5
    80003dd0:	0048581b          	srliw	a6,a6,0x4
    80003dd4:	0115f5b3          	and	a1,a1,a7
    80003dd8:	0046969b          	slliw	a3,a3,0x4
    80003ddc:	0106e6b3          	or	a3,a3,a6
    80003de0:	0025d59b          	srliw	a1,a1,0x2
    80003de4:	0026161b          	slliw	a2,a2,0x2
    80003de8:	8e4d                	or	a2,a2,a1
    80003dea:	0336fe13          	andi	t3,a3,51
    80003dee:	6595                	lui	a1,0x5
    80003df0:	0cc6f693          	andi	a3,a3,204
    80003df4:	786d                	lui	a6,0xffffb
    80003df6:	55558593          	addi	a1,a1,1365 # 5555 <_start-0x7fffaaab>
    80003dfa:	aaa80813          	addi	a6,a6,-1366 # ffffffffffffaaaa <__bss_end+0xffffffff7fff62fa>
    80003dfe:	0026de9b          	srliw	t4,a3,0x2
    80003e02:	002e1e1b          	slliw	t3,t3,0x2
    80003e06:	00b676b3          	and	a3,a2,a1
    80003e0a:	01de6e33          	or	t3,t3,t4
    80003e0e:	01067633          	and	a2,a2,a6
    80003e12:	0016969b          	slliw	a3,a3,0x1
    80003e16:	0016561b          	srliw	a2,a2,0x1
    80003e1a:	055e7f13          	andi	t5,t3,85
    80003e1e:	0aae7e13          	andi	t3,t3,170
    80003e22:	00c6eeb3          	or	t4,a3,a2
    80003e26:	001f1f1b          	slliw	t5,t5,0x1
    80003e2a:	001e5e1b          	srliw	t3,t3,0x1
    80003e2e:	01cf6e33          	or	t3,t5,t3
    80003e32:	008ede9b          	srliw	t4,t4,0x8
    80003e36:	01ceceb3          	xor	t4,t4,t3
    80003e3a:	00000e17          	auipc	t3,0x0
    80003e3e:	736e0e13          	addi	t3,t3,1846 # 80004570 <errpat+0x38>
    80003e42:	8e55                	or	a2,a2,a3
    80003e44:	21cea6b3          	sh1add	a3,t4,t3
    80003e48:	0006d683          	lhu	a3,0(a3)
    80003e4c:	0086161b          	slliw	a2,a2,0x8
    80003e50:	0085551b          	srliw	a0,a0,0x8
    80003e54:	8e35                	xor	a2,a2,a3
    80003e56:	03061e93          	slli	t4,a2,0x30
    80003e5a:	0ff6f693          	zext.b	a3,a3
    80003e5e:	038ed613          	srli	a2,t4,0x38
    80003e62:	06a2                	slli	a3,a3,0x8
    80003e64:	8ed1                	or	a3,a3,a2
    80003e66:	00e6f633          	and	a2,a3,a4
    80003e6a:	0066f6b3          	and	a3,a3,t1
    80003e6e:	0046d69b          	srliw	a3,a3,0x4
    80003e72:	0046161b          	slliw	a2,a2,0x4
    80003e76:	8e55                	or	a2,a2,a3
    80003e78:	00f676b3          	and	a3,a2,a5
    80003e7c:	01167633          	and	a2,a2,a7
    80003e80:	0026561b          	srliw	a2,a2,0x2
    80003e84:	0026969b          	slliw	a3,a3,0x2
    80003e88:	8ed1                	or	a3,a3,a2
    80003e8a:	00b6f633          	and	a2,a3,a1
    80003e8e:	0106f6b3          	and	a3,a3,a6
    80003e92:	0016d69b          	srliw	a3,a3,0x1
    80003e96:	0016161b          	slliw	a2,a2,0x1
    80003e9a:	8e55                	or	a2,a2,a3
    80003e9c:	0ff67693          	zext.b	a3,a2
    80003ea0:	06a2                	slli	a3,a3,0x8
    80003ea2:	8221                	srli	a2,a2,0x8
    80003ea4:	8e55                	or	a2,a2,a3
    80003ea6:	00e676b3          	and	a3,a2,a4
    80003eaa:	00667eb3          	and	t4,a2,t1
    80003eae:	004ede9b          	srliw	t4,t4,0x4
    80003eb2:	00f57613          	andi	a2,a0,15
    80003eb6:	0046969b          	slliw	a3,a3,0x4
    80003eba:	0f057513          	andi	a0,a0,240
    80003ebe:	01d6e6b3          	or	a3,a3,t4
    80003ec2:	0045551b          	srliw	a0,a0,0x4
    80003ec6:	0046161b          	slliw	a2,a2,0x4
    80003eca:	8e49                	or	a2,a2,a0
    80003ecc:	0116feb3          	and	t4,a3,a7
    80003ed0:	00f6f533          	and	a0,a3,a5
    80003ed4:	002ede9b          	srliw	t4,t4,0x2
    80003ed8:	03367693          	andi	a3,a2,51
    80003edc:	0025151b          	slliw	a0,a0,0x2
    80003ee0:	0cc67613          	andi	a2,a2,204
    80003ee4:	01d56533          	or	a0,a0,t4
    80003ee8:	0026561b          	srliw	a2,a2,0x2
    80003eec:	0026969b          	slliw	a3,a3,0x2
    80003ef0:	8ed1                	or	a3,a3,a2
    80003ef2:	00b57633          	and	a2,a0,a1
    80003ef6:	01057533          	and	a0,a0,a6
    80003efa:	0556ff13          	andi	t5,a3,85
    80003efe:	0016161b          	slliw	a2,a2,0x1
    80003f02:	0015551b          	srliw	a0,a0,0x1
    80003f06:	0aa6f693          	andi	a3,a3,170
    80003f0a:	00a66eb3          	or	t4,a2,a0
    80003f0e:	0016d69b          	srliw	a3,a3,0x1
    80003f12:	001f1f1b          	slliw	t5,t5,0x1
    80003f16:	00df6f33          	or	t5,t5,a3
    80003f1a:	008ed69b          	srliw	a3,t4,0x8
    80003f1e:	01e6c6b3          	xor	a3,a3,t5
    80003f22:	21c6a6b3          	sh1add	a3,a3,t3
    80003f26:	0006d683          	lhu	a3,0(a3)
    80003f2a:	008e961b          	slliw	a2,t4,0x8
    80003f2e:	8e35                	xor	a2,a2,a3
    80003f30:	03061513          	slli	a0,a2,0x30
    80003f34:	0ff6f693          	zext.b	a3,a3
    80003f38:	03855613          	srli	a2,a0,0x38
    80003f3c:	06a2                	slli	a3,a3,0x8
    80003f3e:	8ed1                	or	a3,a3,a2
    80003f40:	8f75                	and	a4,a4,a3
    80003f42:	0066f6b3          	and	a3,a3,t1
    80003f46:	0046d69b          	srliw	a3,a3,0x4
    80003f4a:	0047171b          	slliw	a4,a4,0x4
    80003f4e:	8f55                	or	a4,a4,a3
    80003f50:	8ff9                	and	a5,a5,a4
    80003f52:	01177733          	and	a4,a4,a7
    80003f56:	0027571b          	srliw	a4,a4,0x2
    80003f5a:	0027979b          	slliw	a5,a5,0x2
    80003f5e:	8fd9                	or	a5,a5,a4
    80003f60:	00b7f533          	and	a0,a5,a1
    80003f64:	0107f7b3          	and	a5,a5,a6
    80003f68:	0017d79b          	srliw	a5,a5,0x1
    80003f6c:	0015151b          	slliw	a0,a0,0x1
    80003f70:	8d5d                	or	a0,a0,a5
    80003f72:	8082                	ret

0000000080003f74 <check_data_types>:
    80003f74:	4501                	li	a0,0
    80003f76:	8082                	ret
