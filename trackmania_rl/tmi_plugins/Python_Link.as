Net::Socket@ sock = null;
Net::Socket@ clientSock = null;

enum MessageType {
    SCRunStepSync = 1,
    SCCheckpointCountChangedSync = 2,
    SCLapCountChangedSync = 3,
    SCRequestedFrameSync = 4,
    SCOnConnectSync = 5,
    CSetSpeed = 6,
    CRewindToState = 7,
    CRewindToCurrentState = 8,
    CGetSimulationState = 9,
    CSetInputState = 10,
    CGiveUp = 11,
    CPreventSimulationFinish = 12,
    CShutdown = 13,
    CExecuteCommand = 14,
    CSetTimeout = 15,
    CRaceFinished = 16,
    CRequestFrame = 17,
    CResetCamera = 18,
    CSetOnStepPeriod = 19,
}

const bool debug = false;
const string HOST = "127.0.0.1";
const uint16 PORT = 8477;
uint RESPONSE_TIMEOUT = 2000;
int next_frame_requested_H = -1;
int next_frame_requested_W = -1;
int on_step_period = 10;
bool on_connect_queued = false;

void Init_Socket(){
    if (@sock is null) {
        @sock = Net::Socket();
        sock.Listen(HOST, PORT);
    }
}

void close_connection(){
    @clientSock = null;
    Init_Socket();
    next_frame_requested_H = -1;
    RESPONSE_TIMEOUT = 2000;
}

void WaitForResponse(MessageType type){
    auto now = Time::Now;

    while (true) {
        auto receivedType = HandleMessage();
        if (receivedType == type) {
            break;
        }

        if (receivedType == MessageType::CShutdown) {
            break;
        }

        if (receivedType == -1 && Time::Now - now > RESPONSE_TIMEOUT) {
            log("Client disconnected due to timeout (" + RESPONSE_TIMEOUT + "ms)");
            close_connection();
            break;
        }
    }
}

int HandleMessage()
{
    if (clientSock.Available == 0) {
        return -1;
    }

    int type = clientSock.ReadInt32();
    switch(type) {
        case MessageType::SCRunStepSync: {
            break;
        }

        case MessageType::SCRequestedFrameSync: {
            break;
        }

        case MessageType::SCCheckpointCountChangedSync: {
            break;
        }

        case MessageType::SCOnConnectSync: {
            break;
        }

        case MessageType::CSetSpeed: {
            auto@ simManager = GetSimulationManager();
            if(debug){
                print("Server: SetSpeed message");
            }
            float new_speed = clientSock.ReadFloat();
            simManager.SetSpeed(new_speed);
            if(debug){
                print("Server: Set speed to "+new_speed);
            }
            break;
        }

        case MessageType::CGiveUp: {
            auto@ simManager = GetSimulationManager();
            if(debug){
                print("Server: Give up");
            }
            if (simManager.InRace) {
                simManager.GiveUp();
            }
            break;
        }

        case MessageType::CPreventSimulationFinish: {
            auto@ simManager = GetSimulationManager();
            if(debug){
                print("Server: prevent simulation finish");
            }
            if (simManager.InRace) {
                simManager.PreventSimulationFinish();
            }
            break;
        }

        case MessageType::CRewindToState: {
            int32 stateLength = clientSock.ReadInt32();
            auto stateData = clientSock.ReadBytes(stateLength);
            auto@ simManager = GetSimulationManager();
            if(debug){
                print("Server: rewind message");
            }
            if (simManager.InRace) {
                SimulationState state(stateData);
                simManager.RewindToState(state);
            }
            break;            
        }

        case MessageType::CRewindToCurrentState: {
            auto@ simManager = GetSimulationManager();
            if (simManager.InRace) {
                simManager.RewindToState(simManager.SaveState());
            }
            break;
        }

        case MessageType::CGetSimulationState: {
            auto@ simManager = GetSimulationManager();
            auto@ state = simManager.SaveState();
            auto@ data = state.ToArray();
            if(debug){
                print("Server: get_simulation_state");
            }

            clientSock.Write(int(data.Length));
            clientSock.Write(data);
            break;
        }

        case MessageType::CSetInputState: {
            if(debug){
                print("Server: Set input state message");
            }
            bool left = clientSock.ReadUint8()>0;
            bool right = clientSock.ReadUint8()>0;
            bool accelerate = clientSock.ReadUint8()>0;
            bool brake = clientSock.ReadUint8()>0;

            if(debug){
                print("Set input state to "+left+right+accelerate+brake);
            }

            auto@ simManager = GetSimulationManager();
            if (simManager.InRace) {
                simManager.SetInputState(InputType::Left, left?1:0);
                simManager.SetInputState(InputType::Right, right?1:0);
                simManager.SetInputState(InputType::Up, accelerate?1:0);
                simManager.SetInputState(InputType::Down, brake?1:0);
            }

            break;
        }

        case MessageType::CShutdown: {
            log("Client disconnected");
            close_connection();
            break;
        }

        case MessageType::CExecuteCommand: {
            const int32 bytes_to_read = clientSock.ReadInt32();
            const string command = clientSock.ReadString(bytes_to_read);
            if(debug){
                print("Server: command "+command+" received");
            }
            ExecuteCommand(command);
            break;
        }

        case MessageType::CSetTimeout: {
            const uint new_timeout = clientSock.ReadUint32();
            if(debug){
                print("Server: set timeout to "+new_timeout);
            }
            RESPONSE_TIMEOUT = new_timeout;
            break;
        }

        case MessageType::CRaceFinished: {
            auto@ simManager = GetSimulationManager();
            int is_race_finished = ((simManager.PlayerInfo.RaceFinished || simManager.TickTime>simManager.RaceTime)?1:0);
            if(debug){
                print("Server: Answering race_finished with "+is_race_finished);
            }
            clientSock.Write(is_race_finished);
            break;
        }

        case MessageType::CRequestFrame: {
            next_frame_requested_W = clientSock.ReadInt32();
            next_frame_requested_H = clientSock.ReadInt32();
            if(debug){
                print("Client requested next frame in size "+next_frame_requested_H+" "+next_frame_requested_W);
            }
            break;
        }

        case MessageType::CResetCamera: {
            auto@ simManager = GetSimulationManager();
            simManager.ResetCamera();
            break;
        }

        case MessageType::CSetOnStepPeriod: {
            on_step_period = clientSock.ReadInt32();
            break;
        }

        default: {
            log("Server: got unknown message "+type);
            break;
        }
    }

    return type;
}

void OnRunStep(SimulationManager@ simManager){
    if (@clientSock is null) {
        return;
    }
    if(debug){
        print("Server: OnRunStep");
    }

    if(simManager.RaceTime%on_step_period==0){
        clientSock.Write(MessageType::SCRunStepSync);
        clientSock.Write(simManager.RaceTime);
        WaitForResponse(MessageType::SCRunStepSync);
    }
}

void OnCheckpointCountChanged(SimulationManager@ simManager, int current, int target){
    if (@clientSock is null) {
        return;
    }
    if(debug){
        print("Server: OnCheckpointCountChanged");
    }

    clientSock.Write(MessageType::SCCheckpointCountChangedSync);
    clientSock.Write(current);
    clientSock.Write(target);
    WaitForResponse(MessageType::SCCheckpointCountChangedSync);
}

void OnLapCountChanged(SimulationManager@ simManager, int current, int target){
    if (@clientSock is null) {
        return;
    }
    if(debug){
        print("Server: OnLapCountChanged");
    }

    clientSock.Write(MessageType::SCLapCountChangedSync);
    clientSock.Write(current);
    clientSock.Write(target);
    WaitForResponse(MessageType::SCLapCountChangedSync);
}

void OnConnect(){
    clientSock.Write(MessageType::SCOnConnectSync);
    WaitForResponse(MessageType::SCOnConnectSync);
}

void Main(){
    Init_Socket();
}

void OnGameStateChanged(TM::GameState state){
    if(state == TM::GameState::Menus && on_connect_queued){
        OnConnect();
    }
}

void Render(){
    //Bluescreens if you print every Render()
    auto @newSock = sock.Accept(0);
    if (@newSock !is null) {
        @clientSock = @newSock;
        log("Client connected (IP: " + clientSock.RemoteIP + ")");
        if(GetCurrentGameState() != TM::GameState::StartUp){
            OnConnect();
        }
        else{
            on_connect_queued = true;
        }
    }
    if(next_frame_requested_H>=0){
        clientSock.Write(MessageType::SCRequestedFrameSync);
        auto frame = Graphics::CaptureScreenshot(vec2(next_frame_requested_W,next_frame_requested_H));
        clientSock.Write(frame);
        WaitForResponse(MessageType::SCRequestedFrameSync);
        next_frame_requested_H = -1;
        if(debug){
            print("Got response from client for SCRequestedFrameSync");
        }
    }
}

PluginInfo@ GetPluginInfo(){
    PluginInfo info;
    info.Author = "Agade";
    info.Name = "Python Link";
    info.Description = "Reproduce close to original TMI <2 python interface with TMI 2.1 sockets";
    info.Version = "0.1";
    return info;
}