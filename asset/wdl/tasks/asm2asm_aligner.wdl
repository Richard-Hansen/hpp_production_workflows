version 1.0

import "long_read_aligner.wdl" as aligner_t
workflow asm2asmAlignment {
    input {
        String aligner="winnowmap"
        String preset
        File queryAssemblyFastaGz
        File refAssemblyFastaGz
        String zones = "us-west2-a"
    }
    ## align query assembly to the ref assembly
    call aligner_t.alignment{
        input:
            aligner =  aligner,
            preset = "asm20",
            refAssembly = refAssemblyFastaGz,
            readFastq_or_queryAssembly = queryAssemblyFastaGz,
            kmerSize = 19,
            diskSize = 64,
            preemptible = 2,
            zones = zones
    }
    output {
        File sortedBamFile = alignment.sortedBamFile
    }
}