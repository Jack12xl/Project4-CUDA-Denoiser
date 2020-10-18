#pragma once
#include <cuda.h>
#include <cuda_runtime.h>
#include <chrono>
/**
       * This class is used for timing the performance
       * Uncopyable and unmovable
       *
       * Adapted from WindyDarian(https://github.com/WindyDarian)
       */
class PerformanceTimer
{
public:
    PerformanceTimer()
    {
       // cudaEventCreate(&event_start);
        //cudaEventCreate(&event_end);
    }

    ~PerformanceTimer()
    {
        //cudaEventDestroy(event_start);
        //cudaEventDestroy(event_end);
    }

    void startCpuTimer()
    {
        if (cpu_timer_started) { throw std::runtime_error("CPU timer already started"); }
        cpu_timer_started = true;

        time_start_cpu = std::chrono::high_resolution_clock::now();
    }

    void endCpuTimer()
    {
        time_end_cpu = std::chrono::high_resolution_clock::now();

        if (!cpu_timer_started) { throw std::runtime_error("CPU timer not started"); }

        std::chrono::duration<double, std::milli> duro = time_end_cpu - time_start_cpu;
        prev_elapsed_time_cpu_milliseconds =
            static_cast<decltype(prev_elapsed_time_cpu_milliseconds)>(duro.count());

        cpu_timer_started = false;
    }

    void startGpuTimer()
    {
        if (gpu_timer_started) { throw std::runtime_error("GPU timer already started"); }
        gpu_timer_started = true;

        //cudaEventRecord(event_start);
    }

    void endGpuTimer()
    {
        //cudaEventRecord(event_end);
        //cudaEventSynchronize(event_end);

        if (!gpu_timer_started) { throw std::runtime_error("GPU timer not started"); }

       // cudaEventElapsedTime(&prev_elapsed_time_gpu_milliseconds, event_start, event_end);

        gpu_timer_started = false;
    }

    void startSysTimer() {
        if (system_timer_started) { 
            //throw std::runtime_error("System timer already started"); 
        }
        system_timer_started = true;
        time_start_system = std::chrono::steady_clock::now();
    }

    void endSysTimer() {
        if (!system_timer_started) { 
            //throw std::runtime_error("System timer not started"); 
            return;
        }
        system_timer_started = false;
        time_end_system = std::chrono::steady_clock::now();

        prev_elapsed_time_sys_milliseconds = std::chrono::duration_cast<std::chrono::milliseconds> (time_end_system - time_start_system).count();
        //std::cout <<(time_end_system - time_start_system).count()  << std::endl;
        //std::cout << std::chrono::duration_cast<std::chrono::microseconds>(time_end_system - time_start_system).count() << std::endl;
    }

    float getCpuElapsedTimeForPreviousOperation() //noexcept //(damn I need VS 2015
    {
        return prev_elapsed_time_cpu_milliseconds;
    }

    float getGpuElapsedTimeForPreviousOperation() //noexcept
    {
        return prev_elapsed_time_gpu_milliseconds;
    }

    float getSysElapsedTimeForPreviousOperation() //noexcept
    {
        return prev_elapsed_time_sys_milliseconds;
    }

    // remove copy and move functions
    PerformanceTimer(const PerformanceTimer&) = delete;
    PerformanceTimer(PerformanceTimer&&) = delete;
    PerformanceTimer& operator=(const PerformanceTimer&) = delete;
    PerformanceTimer& operator=(PerformanceTimer&&) = delete;

private:
    //cudaEvent_t event_start = nullptr;
    //cudaEvent_t event_end = nullptr;

    using time_point_t = std::chrono::high_resolution_clock::time_point;
    time_point_t time_start_cpu;
    time_point_t time_end_cpu;

    std::chrono::steady_clock::time_point time_start_system;
    std::chrono::steady_clock::time_point time_end_system;

    bool cpu_timer_started = false;
    bool gpu_timer_started = false;
    bool system_timer_started = false;

    float prev_elapsed_time_cpu_milliseconds = 0.f;
    float prev_elapsed_time_gpu_milliseconds = 0.f;
    double prev_elapsed_time_sys_milliseconds = 0.f;
};