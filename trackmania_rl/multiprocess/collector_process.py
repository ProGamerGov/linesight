import importlib
import time
from itertools import chain, count, cycle
from pathlib import Path

import numpy as np
import torch
from torch import multiprocessing as mp

from trackmania_rl import misc, nn_utilities
from trackmania_rl.agents import iqn as iqn


def collector_process_fn(rollout_queue, model_queue, shared_steps: mp.Value, base_dir: Path, save_dir: Path, tmi_port: int):
    from trackmania_rl.map_loader import analyze_map_cycle, load_next_map_zone_centers
    from trackmania_rl.tmi_interaction import tm_interface_manager

    tmi = tm_interface_manager.TMInterfaceManager(
        base_dir=base_dir,
        running_speed=misc.running_speed,
        run_steps_per_action=misc.tm_engine_step_per_action,
        max_overall_duration_ms=misc.cutoff_rollout_if_race_not_finished_within_duration_ms,
        max_minirace_duration_ms=misc.cutoff_rollout_if_no_vcp_passed_within_duration_ms,
        tmi_port=tmi_port,
    )

    inference_network = iqn.make_untrained_iqn_network(misc.use_jit)
    try:
        inference_network.load_state_dict(torch.load(save_dir / "weights1.torch"))
    except Exception as e:
        print("Worker could not load weights, exception:",e)

    inferer = iqn.Inferer(inference_network, misc.iqn_k, misc.tau_epsilon_boltzmann)

    # ========================================================
    # Training loop
    # ========================================================
    inference_network.train()

    map_cycle_str = str(misc.map_cycle)
    set_maps_trained, set_maps_blind = analyze_map_cycle(misc.map_cycle)
    map_cycle_iter = cycle(chain(*misc.map_cycle))

    zone_centers_filename = None

    # ========================================================
    # Warmup pytorch and numba
    # ========================================================
    for _ in range(5):
        inferer.infer_network(
            np.random.randint(low=0, high=255, size=(1, misc.H_downsized, misc.W_downsized), dtype=np.uint8),
            np.random.rand(misc.float_input_dim).astype(np.float32),
        )
    # tm_interface_manager.update_current_zone_idx(0, zone_centers, np.zeros(3))

    for loop_number in count(1):
        importlib.reload(misc)

        tmi.max_minirace_duration_ms = misc.cutoff_rollout_if_no_vcp_passed_within_duration_ms

        # ===============================================
        #   DID THE CYCLE CHANGE ?
        # ===============================================
        if str(misc.map_cycle) != map_cycle_str:
            map_cycle_str = str(misc.map_cycle)
            set_maps_trained, set_maps_blind = analyze_map_cycle(misc.map_cycle)
            map_cycle_iter = cycle(chain(*misc.map_cycle))

        # ===============================================
        #   GET NEXT MAP FROM CYCLE
        # ===============================================
        next_map_tuple = next(map_cycle_iter)
        if next_map_tuple[2] != zone_centers_filename:
            zone_centers = load_next_map_zone_centers(next_map_tuple[2], base_dir)
        map_name, map_path, zone_centers_filename, is_explo, fill_buffer = next_map_tuple
        map_status = "trained" if map_name in set_maps_trained else "blind"

        inferer.epsilon = nn_utilities.from_exponential_schedule(misc.epsilon_schedule, shared_steps.value)
        inferer.epsilon_boltzmann = nn_utilities.from_exponential_schedule(misc.epsilon_boltzmann_schedule, shared_steps.value)
        inferer.tau_epsilon_boltzmann = misc.tau_epsilon_boltzmann
        inferer.is_explo = is_explo

        # Check for weight update
        if not model_queue.empty():  # Make sure we get latest weights in the pipe, and make sure the pipe can't start accumulating
            while True:
                model_state_dict = model_queue.get()
                if model_queue.empty():
                    inference_network.load_state_dict(model_state_dict)
                    break

        # ===============================================
        #   PLAY ONE ROUND
        # ===============================================

        rollout_start_time = time.perf_counter()

        if inference_network.training and not is_explo:
            inference_network.eval()
        elif is_explo and not inference_network.training:
            inference_network.train()

        rollout_results, end_race_stats = tmi.rollout(
            exploration_policy=inferer.get_exploration_action,
            map_path=map_path,
            zone_centers=zone_centers,
        )
        rollout_duration = time.perf_counter() - rollout_start_time
        print("", flush=True)

        if not tmi.last_rollout_crashed:
            rollout_queue.put(
                (
                    rollout_results,
                    end_race_stats,
                    fill_buffer,
                    is_explo,
                    map_name,
                    map_status,
                    rollout_duration,
                    loop_number,
                )
            )