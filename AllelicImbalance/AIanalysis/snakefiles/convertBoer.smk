#!/usr/bin/env python3
import os
import glob

# Get OA_types 
OA_types = os.listdir("/proj/phanstiel_lab/External/gwas/OA/Boer_2021_hg19/")
# Remove README and other
OA_types = [i for i in OA_types if i not in ('other', 'README')]

rule all:
    input:
        [expand('data/Boer_{subtype}_LD_rsids.csv', subtype = OA_types)]


rule convertBoer:
    input:
        lambda wildcards: '/proj/phanstiel_lab/External/gwas/OA/Boer_2021_hg19/{subtype}/LD/LD_Boer_2021_{subtype}.txt'.format(subtype=wildcards.subtype)
    output:
        'data/Boer_{subtype}_LD_rsids.csv'
    params:
        subtype = lambda wildcards: wildcards.subtype
    log:
        out = "logs/convertBoer_{subtype}.out"
    shell:
        """
        module load samtools
        module load python/3.9.6
        python3 scripts/convertBoer.py {input} {params.subtype} 1> {log.out}
        """
    