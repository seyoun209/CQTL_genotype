#!/usr/bin/env python3

import pandas as pd
import os, shutil

## Load config file
configfile: "config/config.yaml"

## Read in samplesheet
samples = pd.read_csv(config["samplesheet"],sep=",")

## Convert samplesheet columns to strings
samples = samples.astype(str)

## Concatenate Sequencing_Directory to Read1 and Read2 for full read paths
samples['Read1'] = samples[['Sequencing_Directory', 'Read1']].apply(lambda row: os.path.join(*row), axis=1)
samples['Read2'] = samples[['Sequencing_Directory', 'Read2']].apply(lambda row: os.path.join(*row), axis=1)

## Group Seq_Reps
samples['id'] = samples[['Proj', 'Donor']].agg('_'.join, axis=1) + '_R_' + samples[['Condition', 'Time', 'Tech_Rep']].agg('_'.join, axis=1)

## Extract grouped read1 and read2s
read1 = samples.groupby(['id'])['Read1'].apply(list).to_dict()
read2 = samples.groupby(['id'])['Read2'].apply(list).to_dict()

## Get vcf file path of post-imputed, qc'd gzipped vcf file
vcf = config["vcf"]
vcf_file = os.path.basename(vcf)
vcf_prefix = vcf_file[:re.search("_ALL_qc.vcf.gz", vcf_file).span()[0]]

## Define actions on success
onsuccess:

    ## Success message
    print("Allelic imbalance RNA processing finished successfully!")

    ## Remove trim directory
    for key in read1:
        shutil.rmtree(os.path.join('output', key, 'trim'))
    os.remove('editDonors.done')

## Define rules
rule all:
    input:
        [expand("output/{group}/alleleCounts/{group}_alleleCounts.csv", group = key) for key in read1],
        'editDonors.done'

rule catR1:
    input:
        lambda wildcards: read1.get(wildcards.group)
    output:
        "output/{group}/fastq/{group}_R1.fastq.gz"
    threads: 1
    log:
        err = "output/{group}/logs/{group}_catR1.err"
    shell:
        """
        mkdir -p output/{wildcards.group}/fastq
        cat {input} > {output} 2> {log.err}
        """

#include: "../../rules/catR1.rule"
#include: "../../rules/catR2.rule"

rule catR2:
    input:
        lambda wildcards: read2.get(wildcards.group)
    output:
        "output/{group}/fastq/{group}_R2.fastq.gz"
    threads: 1
    log:
        err = "output/{group}/logs/{group}_catR2.err"
    shell:
        """
        mkdir -p output/{wildcards.group}/fastq
        cat {input} > {output} 2> {log.err}
        """

#include: "../../rules/qc.rule"

rule qc:
    input:
        R1 = lambda wildcards: ['output/{group}/fastq/{group}_R1.fastq.gz'.format(group=wildcards.group)],
        R2 = lambda wildcards: ['output/{group}/fastq/{group}_R2.fastq.gz'.format(group=wildcards.group)]
    output:
        zip = expand('output/{{group}}/qc/{{group}}_{R}_fastqc.zip', R=['R1', 'R2']),
        html = expand('output/{{group}}/qc/{{group}}_{R}_fastqc.html',R=['R1', 'R2'])
    threads: 2
    log:
        err = "output/{group}/logs/{group}_qc.err"
    shell:
        """
        module load fastqc/0.11.8
        mkdir -p output/{wildcards.group}/qc
        fastqc -t {threads} -o output/{wildcards.group}/qc {input.R1} {input.R2} 2> {log.err}
        """

#include: "../../rules/trim.rule"

rule trim:
    input:
        R1 = lambda wildcards: ['output/{group}/fastq/{group}_R1.fastq.gz'.format(group=wildcards.group)],
        R2 = lambda wildcards: ['output/{group}/fastq/{group}_R2.fastq.gz'.format(group=wildcards.group)]
    output:
        trim1 = temp("output/{group}/trim/{group}_R1_val_1.fq.gz"),
        trim2 = temp("output/{group}/trim/{group}_R2_val_2.fq.gz")
    threads: 4
    log:
        err = "output/{group}/logs/{group}_trim.err"
    shell:
        """
        module load trim_galore/0.6.2
        module load python/3.6.6
        module load pigz
        mkdir -p output/{wildcards.group}/trim
        trim_galore -o output/{wildcards.group}/trim --cores {threads} --path_to_cutadapt /nas/longleaf/apps/cutadapt/2.9/venv/bin/cutadapt --paired {input.R1} {input.R2} 2> {log.err}
        """

rule align:
    input:
        R1 = rules.trim.output.trim1,
        R2 = rules.trim.output.trim2,
        vcf = 'output/vcf/' + vcf_prefix + '_nodups_biallelic.vcf.gz',
        i = 'output/vcf/' + vcf_prefix + '_nodups_biallelic.vcf.gz.tbi'
    output:
        "output/{group}/align/{group}.Aligned.sortedByCoord.out.bam"
    threads: 8
    log:
        out = "output/{group}/logs/{group}_align.out"
    params:
        genomeDir = config['genomeDir']
    shell:
        'module load star/2.7.0a &&'
        'mkdir -p output/{wildcards.group}/align &&'
        'star --runThreadN {threads} '
        '--genomeDir {params.genomeDir} '
        '--readFilesCommand zcat ' 
        '--readFilesIn {input.R1} {input.R2} '
        '--outFileNamePrefix output/{wildcards.group}/align/{wildcards.group}. ' 
        '--outSAMtype BAM SortedByCoordinate '
        '--outFilterType BySJout '
        '--outFilterMultimapNmax 20 ' 
        '--alignSJoverhangMin 8 ' 
        '--alignSJDBoverhangMin 1 '
        '--outFilterMismatchNmax 999 ' 
        '--outFilterMismatchNoverReadLmax 0.04 ' 
        '--alignIntronMin 20 ' 
        '--alignIntronMax 1000000 '
        '--alignMatesGapMax 1000000 '
        '--waspOutputMode SAMtag '
        '--varVCFfile <(zcat {input.vcf})'

#include: "../../rules/index.rule"

rule index:
    input:
        rules.align.output
    output:
        "output/{group}/align/{group}.Aligned.sortedByCoord.out.bam.bai"
    threads: 8
    log:
        err = "output/{group}/logs/{group}_index.err"
    shell:
        """
        module load samtools
        samtools index -@ {threads} {input} {output} 2> {log.err}
        """

rule assignGroups:
    input:
        R = rules.align.output,
        I = rules.index.output
    output:
        "output/{group}/grouped/{group}.grouped.sort.bam"
    threads: 1
    log:
        err = "output/{group}/logs/{group}_assignGroups.err"
    shell:
        """
        mkdir -p output/{wildcards.group}/grouped
        module load picard/2.2.4
        module load java/10.0.2
        java -jar /nas/longleaf/apps/picard/2.2.4/picard-tools-2.2.4/picard.jar AddOrReplaceReadGroups I={input.R} O={output} RGLB=lib1 RGPL=illumina RGPU=unit1 RGSM={wildcards.group} SORT_ORDER=coordinate 2> {log.err}
        """

rule countReads:
    input:
        bam = rules.assignGroups.output,
        vcf = 'output/vcf/' + vcf_prefix + '_nodups_biallelic.vcf.gz',
        i = 'output/vcf/' + vcf_prefix + '_nodups_biallelic.vcf.gz.tbi'
    output:
        "output/{group}/alleleCounts/{group}_alleleCounts.csv"
    threads: 1
    log:
        err = "output/{group}/logs/{group}_countReads.err"
    params:
        sequence = config['sequence']
    shell:
        """
        mkdir -p output/{wildcards.group}/alleleCounts
        module load gatk/4.1.7.0
        module load python/3.6.6
        gatk ASEReadCounter --input {input.bam} --variant {input.vcf} --output {output} --output-format RTABLE --min-base-quality 20 --disable-read-filter NotDuplicateReadFilter --reference {params.sequence} 2> {log.err}
        """

rule editDonors:
    input:
        vcf = 'output/vcf/' + vcf_prefix + '_nodups_biallelic.vcf.gz'
    output:
        touch('editDonors.done')
    params:
        donors = ",".join(samples['Donor'].unique().tolist())
    shell:
        """
        module load samtools
        module load python/3.9.6
        bcftools query -l {input.vcf} > donors.txt

        python3 scripts/RNAproc/matchDonors.py donors.txt {params.donors}
        """