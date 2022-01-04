version 1.0

import "../tasks/cov2counts.wdl" as cov2counts_t
import "../tasks/cov2counts_contig_wise.wdl" as cov2counts_contig_wise_t
import "../tasks/fit_model.wdl" as fit_model_t
import "../tasks/fit_model_contig_wise.wdl" as fit_model_contig_wise_t
import "../tasks/find_blocks.wdl" as find_blocks_t
import "../tasks/find_blocks_contig_wise.wdl" as find_blocks_contig_wise_t
import "../tasks/pdf_generator.wdl" as pdf_generator_t
import "../tasks/bedtools.wdl" as bedtools_t
import "../tasks/fit_model_bed.wdl" as fit_model_bed_t

workflow runCoverageAnalysisV1{
    input {
        File matHsat1Bed = "gs://hprc/null.bed"
        File patHsat1Bed = "gs://hprc/null.bed"
        File matHsat2Bed = "gs://hprc/null.bed"
        File patHsat2Bed = "gs://hprc/null.bed"
        File matHsat3Bed = "gs://hprc/null.bed"
        File patHsat3Bed = "gs://hprc/null.bed"
        File coverageGz
        File highMapqCoverageGz
        File fai
        Float covFloat
        Boolean isDiploid
    }
    scatter (bedAndFactor in zip([matHsat1Bed, patHsat1Bed, matHsat2Bed, patHsat2Bed, matHsat3Bed, patHsat3Bed], [(0.75, "mat_hsat1"), (0.75, "pat_hsat1"), (1.25, "mat_hsat2"), (1.25, "pat_hsat2"), (1.25, "mat_hsat3"), (1.25, "pat_hsat3")])){
        call bedtools_t.merge {
            input:
                bed = bedAndFactor.left,
                margin = 50000,
                outputPrefix = basename("${bedAndFactor.left}", ".bed")
        } 
        call fit_model_bed_t.runFitModelBed as hsatModels {
            input:
                bed = merge.mergedBed,
                suffix = bedAndFactor.right.right,
                coverageGz = coverageGz,
                covFloat = covFloat * bedAndFactor.right.left
         }
    }
    call mergeHsatBeds {
        input:
            bedsTarGzArray = hsatModels.bedsTarGz
    }
    call cov2counts_t.cov2counts {
        input:
            coverageGz = coverageGz 
    }
    call fit_model_t.fitModel {
        input:
            counts = cov2counts.counts
    }
    call find_blocks_t.findBlocks {
        input:
            coverageGz = coverageGz,
            table = fitModel.probabilityTable
    }
    call cov2counts_contig_wise_t.cov2countsContigWise {
        input:
            coverageGz = coverageGz,
            fai = fai
    }
    call fit_model_contig_wise_t.fitModelContigWise {
        input:
            windowsText = cov2countsContigWise.windowsText,
            countsTarGz = cov2countsContigWise.contigCountsTarGz 
    }
    call find_blocks_contig_wise_t.findBlocksContigWise {
        input:
            contigCovsTarGz = cov2countsContigWise.contigCovsTarGz,
            contigProbTablesTarGz = fitModelContigWise.contigProbTablesTarGz,
            windowsText = cov2countsContigWise.windowsText
    }
    call pdf_generator_t.pdfGenerator {
        input:
            contigProbTablesTarGz = fitModelContigWise.contigProbTablesTarGz,
            genomeProbTable = fitModel.probabilityTable,
            isDiploid = isDiploid
    }
    call combineBeds as combineWindowBased{
        input:
            outputPrefix = "window_corrected",
            firstPrefix = "whole_genome",
            secondPrefix = "window_based",
            firstBedsTarGz = findBlocks.bedsTarGz,
            secondBedsTarGz = findBlocksContigWise.contigBedsTarGz
    }
    call combineBeds as combineHsatBased{
       input:
            outputPrefix = "hsat_corrected",
            firstPrefix = "window_corrected",
            secondPrefix = "hsat_based",
            firstBedsTarGz = combineWindowBased.combinedBedsTarGz,
            secondBedsTarGz = mergeHsatBeds.bedsTarGz
    }    
    call dupCorrectBeds {
        input:
            highMapqCovGz = highMapqCoverageGz,
            bedsTarGz = combineHsatBased.combinedBedsTarGz,
            prefix="hsat_corrected"
    }
    call filterBeds {
        input:
            dupCorrectedBedsTarGz = dupCorrectBeds.dupCorrectedBedsTarGz
    }
    output {
        File genomeCounts = cov2counts.counts
        File genomeProbTable = fitModel.probabilityTable
        File genomeBedsTarGz = findBlocks.bedsTarGz
        File windowCountsTarGz = cov2countsContigWise.contigCountsTarGz
        File windowCovsTarGz = cov2countsContigWise.contigCovsTarGz
        File windowProbTablesTarGz = fitModelContigWise.contigProbTablesTarGz
        File windowBedsTarGz = findBlocksContigWise.contigBedsTarGz
        File pdf = pdfGenerator.pdf
        File combinedBedsTarGz = combineWindowBased.combinedBedsTarGz
        File dupCorrectedBedsTarGz = dupCorrectBeds.dupCorrectedBedsTarGz
        File filteredBedsTarGz = filterBeds.filteredBedsTarGz
        File hsatCorrectedBedsTarGz =  combineHsatBased.combinedBedsTarGz
    }
}

task combineBeds {
    input {
        File firstBedsTarGz
        File secondBedsTarGz
        String firstPrefix
        String secondPrefix
        String outputPrefix = "combined"
        # runtime configurations
        Int memSize=8
        Int threadCount=4
        Int diskSize=128
        String dockerImage="quay.io/masri2019/hpp_coverage:latest"
        Int preemptible=2
    }
    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        # to turn off echo do 'set +o xtrace'
        set -o xtrace
        
        mkdir first second
        tar --strip-components 1 -xvzf ~{firstBedsTarGz} --directory first
        tar --strip-components 1 -xvzf ~{secondBedsTarGz} --directory second
                
        FILENAME=~{firstBedsTarGz}
        PREFIX=$(basename ${FILENAME%.*.*.tar.gz})
        
        cat second/*.bed | bedtools sort -i - | bedtools merge -i - > second_all.bed 
        mkdir first_minus_second ~{outputPrefix}
        for c in error duplicated haploid collapsed
        do
            bedtools subtract -a first/${PREFIX}.~{firstPrefix}.${c}.bed -b second_all.bed > first_minus_second/${PREFIX}.${c}.bed
            cat first_minus_second/*.${c}.bed second/*.${c}.bed | bedtools sort -i - | bedtools merge -i - > ~{outputPrefix}/${PREFIX}.~{outputPrefix}.${c}.bed
        done

        tar -cf ${PREFIX}.beds.~{outputPrefix}.tar ~{outputPrefix}
        gzip ${PREFIX}.beds.~{outputPrefix}.tar

    >>> 
    runtime {
        docker: dockerImage
        memory: memSize + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSize + " SSD"
        preemptible : preemptible
    }
    output {
        File combinedBedsTarGz = glob("*.beds.${outputPrefix}.tar.gz")[0]
    }
}


task dupCorrectBeds {
    input {
        File highMapqCovGz
        File bedsTarGz
        String prefix
        Int minCov=5
        # runtime configurations
        Int memSize=16
        Int threadCount=8
        Int diskSize=128
        String dockerImage="quay.io/masri2019/hpp_coverage:latest"
        Int preemptible=2
    }

    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        # to turn off echo do 'set +o xtrace'
        set -o xtrace
        
        FILENAME=$(basename ~{highMapqCovGz})
        PREFIX=${FILENAME%.cov.gz}

        mkdir ~{prefix}
        tar --strip-components 1 -xvzf ~{bedsTarGz} --directory ~{prefix}

        zcat ~{highMapqCovGz} | \
            awk '{if(substr($1,1,1) == ">") {contig=substr($1,2,40)} else if($3 >= ~{minCov}) {print contig"\t"$1-1"\t"$2}}' | \
            bedtools merge -i - > high_mapq.bed

        mkdir dup_corrected

        # do the correction
        bedtools subtract -a ~{prefix}/${PREFIX}.~{prefix}.duplicated.bed -b high_mapq.bed > dup_corrected/${PREFIX}.dup_corrected.duplicated.bed
        bedtools intersect -a ~{prefix}/${PREFIX}.~{prefix}.duplicated.bed -b high_mapq.bed > dup_to_hap.bed
        cat dup_to_hap.bed ~{prefix}/${PREFIX}.~{prefix}.haploid.bed | bedtools sort -i - | bedtools merge -i - > dup_corrected/${PREFIX}.dup_corrected.haploid.bed
        
        # just copy error and collapsed comps
        cp ~{prefix}/${PREFIX}.~{prefix}.error.bed dup_corrected/${PREFIX}.dup_corrected.error.bed
        cp ~{prefix}/${PREFIX}.~{prefix}.collapsed.bed dup_corrected/${PREFIX}.dup_corrected.collapsed.bed

        tar -cf ${PREFIX}.beds.dup_corrected.tar dup_corrected
        gzip ${PREFIX}.beds.dup_corrected.tar
        
    >>>

    runtime {
        docker: dockerImage
        memory: memSize + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSize + " SSD"
        preemptible : preemptible
    }
    output {
        File dupCorrectedBedsTarGz = glob("*.beds.dup_corrected.tar.gz")[0]
    }
}

task filterBeds {
    input {
        File dupCorrectedBedsTarGz
        Int mergeLength=100
        Int minBlockLength=1000
        # runtime configurations
        Int memSize=8
        Int threadCount=4
        Int diskSize=32
        String dockerImage="quay.io/masri2019/hpp_coverage:latest"
        Int preemptible=2
    }

    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        # to turn off echo do 'set +o xtrace'
        set -o xtrace
        
        mkdir dup_corrected
        tar --strip-components 1 -xvzf ~{dupCorrectedBedsTarGz} --directory dup_corrected

        FILENAME=~{dupCorrectedBedsTarGz}
        PREFIX=$(basename ${FILENAME%.*.*.tar.gz})

        mkdir filtered
        for c in error duplicated haploid collapsed
        do
            bedtools merge -d ~{mergeLength} -i dup_corrected/*.${c}.bed | awk '($3-$2) >= ~{minBlockLength}' > filtered/${PREFIX}.filtered.${c}.bed
        done
        

        tar -cf ${PREFIX}.beds.filtered.tar filtered
        gzip ${PREFIX}.beds.filtered.tar
        
    >>>

    runtime {
        docker: dockerImage
        memory: memSize + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSize + " SSD"
        preemptible : preemptible
    }
    output {
        File filteredBedsTarGz = glob("*.beds.filtered.tar.gz")[0]
    }
}


task mergeHsatBeds {
    input {
        Array[File] bedsTarGzArray
        # runtime configurations
        Int memSize=4
        Int threadCount=2
        Int diskSize=32
        String dockerImage="quay.io/masri2019/hpp_coverage:latest"
        Int preemptible=2
    }
    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        # to turn off echo do 'set +o xtrace'
        set -o xtrace

         
        FILENAMES=(~{sep=" " bedsTarGzArray})
        FILENAME=${FILENAMES[0]}
        PREFIX=$(basename ${FILENAME%.*.*.tar.gz})

        mkdir hsat_unmerged hsat_based
        for s in ~{sep=" " bedsTarGzArray}; do
            tar --strip-components 1 -xvzf $s --directory hsat_unmerged
        done
 
        for comp in error haploid duplicated collapsed; do
            cat hsat_unmerged/*.${comp}.bed | bedtools sort -i - | bedtools merge -i - > hsat_based/$PREFIX.hsat_based.${comp}.bed
        done
         
        tar -cf ${PREFIX}.beds.hsat_based.tar hsat_based
        gzip ${PREFIX}.beds.hsat_based.tar
    >>>

    runtime {
        docker: dockerImage
        memory: memSize + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSize + " SSD"
        preemptible : preemptible
    }
    output {
        File bedsTarGz = glob("*.beds.hsat_based.tar.gz")[0]
    }
}
