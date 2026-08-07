# nixos/config/home/fish/functions/resetgpu.fish

function resetgpu --description 'Toggles NVIDIA persistence mode to try and fix GPU issues'
    echo "Attempting to reset NVIDIA GPU state..."

    echo "Disabling persistence mode..."
    sudo nvidia-smi -pm 0

    echo "State toggled off. Pausing for 2 seconds..."
    sleep 2

    echo "Re-enabling persistence mode..."
    sudo nvidia-smi -pm 1

    echo "Reset complete. Checking final state:"
    nvidia-smi --query-gpu=pstate --format=csv,noheader
end
