#include <nvbio/basic/console.h>
#include <nvbio/basic/shared_pointer.h>
#include <nvbio/basic/cuda/arch.h>
#include <nvbio/io/fmi.h>
#include <nvbio/io/output/output_file.h>
#include <nvbio/io/reads/reads.h>

#include "options.h"
#include "util.h"
#include "pipeline.h"
#include "mem-search.h"

using namespace nvbio;

int main(int argc, char **argv)
{
    parse_command_line(argc, argv);
    gpu_init();

    struct pipeline_context pipeline;
    // load the fmindex and prepare the SMEM search
    mem_init(&pipeline);

    // open the input read file
    SharedPointer<io::ReadDataStream> input = SharedPointer<io::ReadDataStream>(
        io::open_read_file(
            command_line_options.input_file_name,
            io::Phred33,
            uint32(-1),
            uint32(-1),
            io::ReadEncoding(io::FORWARD | io::REVERSE_COMPLEMENT) ) );

    if (input == NULL || input->is_ok() == false)
    {
        log_error(stderr, "failed to open read file %s\n", command_line_options.input_file_name);
        exit(1);
    }

    // open the output file
    pipeline.output = io::OutputFile::open(command_line_options.output_file_name,
            io::SINGLE_END,
            io::BNT(*pipeline.mem.fmindex_data_host));

    if (!pipeline.output)
    {
        log_error(stderr, "failed to open output file %s\n", command_line_options.output_file_name);
        exit(1);
    }

    // go!
    for(;;)
    {
        // read the next batch
        SharedPointer<io::ReadData> batch = SharedPointer<io::ReadData>( input->next(command_line_options.batch_size, uint32(-1)) );
        if (batch == NULL)
        {
            // EOF
            break;
        }

        // copy batch to the device
        const io::ReadDataDevice device_batch(*batch);

        // search for MEMs
        mem_search(&pipeline, &device_batch);

        cudaDeviceSynchronize();
        nvbio::cuda::check_error("mem-search kernel");

        // now start a loop where we break the read batch into smaller chunks for
        // which we can locate all MEMs and build all chains
        for (uint32 read_begin = 0; read_begin < batch->size(); read_begin = pipeline.chunk.read_end)
        {
            log_verbose(stderr, "chunking... started\n");

            // determine the next chunk of reads to process
            fit_read_chunk(&pipeline, &device_batch, read_begin);

            log_verbose(stderr, "chunking... done\n");
            log_verbose(stderr, "  reads : [%u,%u)\n", pipeline.chunk.read_begin, pipeline.chunk.read_end);
            log_verbose(stderr, "  mems  : [%u,%u)\n", pipeline.chunk.mem_begin, pipeline.chunk.mem_end);

            log_verbose(stderr, "locating mems... started\n");

            // locate all MEMs in the current chunk
            mem_locate(&pipeline, &device_batch);

            cudaDeviceSynchronize();
            nvbio::cuda::check_error("mem-locate kernel");

            log_verbose(stderr, "locating mems... done\n");
            log_verbose(stderr, "building chains... started\n");

            // build the chains
            build_chains(&pipeline, &device_batch);

            cudaDeviceSynchronize();
            nvbio::cuda::check_error("build-chains kernel");

            log_verbose(stderr, "building chains... done\n");
        }
    }

    pipeline.output->close();
}
