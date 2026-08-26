import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var bluetooth = BLEManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var enrollmentPhaseStartedAt = Date()
    @State private var calibrationPhaseStartedAt = Date()
    @State private var multiViewPhaseStartedAt = Date()
    @State private var showingProfiles = false
    @State private var showingRenamePrompt = false
    @State private var renameSlot: Int?
    @State private var renameText = ""

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [.black.opacity(0.72), .clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                trackingOverlay(in: geometry.size)
                if bluetooth.isEnrolling {
                    enrollmentOverlay
                }
                if bluetooth.isCalibrating {
                    calibrationOverlay
                }
                if bluetooth.isMultiViewCapturing {
                    multiViewOverlay
                }
                if bluetooth.isChoosingTarget {
                    candidateSelectionOverlay(in: geometry.size)
                }
                // Keep the transport controls above every scan/refine overlay.
                // The candidate layer used to cover the record button, making
                // it impossible to stop during the 3-second/selection phase.
                controls
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            camera.prepare()
            bluetooth.resumeFromForeground()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.resume()
                bluetooth.resumeFromForeground()
            case .inactive, .background:
                camera.suspend()
                bluetooth.suspendForBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: bluetooth.isEnrolling) { _, active in
            if active { enrollmentPhaseStartedAt = Date() }
        }
        .onChange(of: bluetooth.isRefining) { _, active in
            if active { enrollmentPhaseStartedAt = Date() }
        }
        .onChange(of: bluetooth.isCalibrating) { _, active in
            if active { calibrationPhaseStartedAt = Date() }
        }
        .onChange(of: bluetooth.isMultiViewCapturing) { _, active in
            if active { multiViewPhaseStartedAt = Date() }
        }
        .onChange(of: bluetooth.shouldRecordVideo) { _, shouldRecord in
            if shouldRecord {
                camera.startRecording()
            } else if camera.isRecording {
                camera.stopRecording()
            }
        }
        .sheet(isPresented: $showingProfiles) {
            savedProfilesSheet
        }
        .alert("Đổi tên mẫu", isPresented: $showingRenamePrompt) {
            TextField("Tên mẫu", text: $renameText)
            Button("Hủy", role: .cancel) { renameSlot = nil }
            Button("Lưu") {
                if let slot = renameSlot {
                    bluetooth.renameProfile(in: slot, to: renameText)
                }
                renameSlot = nil
            }
        } message: {
            Text("Tên này chỉ dùng để bạn dễ nhận ra mẫu trên iPhone.")
        }
    }

    private var savedProfilesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("MaixCAM lưu đặc trưng thật của tối đa 2 mục tiêu. Khi dùng lại, bạn chỉ cần đưa mẫu vào dấu +, bấm Căn tâm và học bổ sung 3 giây.")
                        .font(.custom("Arial", size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)

                    ForEach(1...2, id: \.self) { slot in
                        savedProfileRow(slot: slot)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Mẫu đã tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { showingProfiles = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func savedProfileRow(slot: Int) -> some View {
        let profile = bluetooth.profile(in: slot)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(profile == nil ? Color.white.opacity(0.08) : Color.orange.opacity(0.18))
                        .frame(width: 46, height: 46)
                    Image(systemName: profile?.mode.icon ?? "plus")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(profile == nil ? .secondary : .orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.name ?? "Ô mẫu \(slot)")
                        .font(.custom("Arial", size: 16).weight(.bold))
                    Text(profile == nil
                         ? "Chưa có dữ liệu"
                         : "\(profile!.mode.title) • lưu trên iPhone + MaixCAM")
                        .font(.custom("Arial", size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if bluetooth.activeProfileSlot == slot {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 9) {
                if let profile {
                    Button {
                        bluetooth.useProfile(profile)
                        showingProfiles = false
                    } label: {
                        Label("Dùng mẫu", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        renameSlot = slot
                        renameText = profile.name
                        showingRenamePrompt = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        bluetooth.deleteProfile(in: slot)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(profile == nil ? "Lưu vào ô này" : "Ghi đè mẫu") {
                    bluetooth.saveCurrentProfile(in: slot)
                }
                .buttonStyle(.bordered)
                .disabled(!bluetooth.canSaveCurrentProfile)
                .opacity(bluetooth.canSaveCurrentProfile ? 1 : 0.38)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var enrollmentOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let duration = 3.0
            let elapsed = max(0, timeline.date.timeIntervalSince(enrollmentPhaseStartedAt))
            // The local clock keeps the ring moving even if one BLE progress
            // packet is delayed.  Stop at 98% until MaixCAM confirms completion.
            let localProgress = min(0.98, elapsed / duration * 0.98)
            let smoothProgress = min(1, max(bluetooth.enrollmentProgress, localProgress))
            let complete = bluetooth.enrollmentProgress >= 0.999
            let remaining = max(1, Int(ceil((1 - smoothProgress) * duration)))
            let activeColor: Color = bluetooth.isRefining ? .cyan : .red
            enrollmentRing(
                progress: smoothProgress,
                complete: complete,
                remaining: remaining,
                activeColor: activeColor
            )
        }
    }

    private var multiViewOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let duration = 3.0
            let elapsed = max(0, timeline.date.timeIntervalSince(multiViewPhaseStartedAt))
            // BLE/UART packets may arrive in small bursts. The local clock keeps
            // the ring visually fluid while MaixCAM remains the completion source.
            let localProgress = min(0.98, elapsed / duration * 0.98)
            let smoothProgress = min(1, max(bluetooth.multiViewProgress, localProgress))
            let complete = bluetooth.multiViewProgress >= 0.999
            let remaining = max(1, Int(ceil((1 - smoothProgress) * duration)))

            ZStack {
                Circle()
                    .fill(.black.opacity(0.58))
                    .frame(width: 184, height: 184)
                    .shadow(color: .black.opacity(0.45), radius: 18)

                Circle()
                    .stroke(.white.opacity(0.20), lineWidth: 8)
                    .frame(width: 160, height: 160)

                Circle()
                    .trim(from: 0, to: max(0.012, smoothProgress))
                    .stroke(
                        complete ? Color.green : Color.purple,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 160, height: 160)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: (complete ? Color.green : Color.purple).opacity(0.56), radius: 7)

                VStack(spacing: 6) {
                    Image(systemName: complete ? "checkmark" : "move.3d")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(complete ? .green : .white)
                    Text(complete ? "XONG" : "\(remaining)")
                        .font(.custom("Arial", size: 30).monospacedDigit().weight(.bold))
                    Text(complete ? "Đã học thêm đa góc" : "Xoay/nghiêng vật chậm")
                        .font(.custom("Arial", size: 12).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: 136)
                }
            }
            .transition(.scale(scale: 0.88).combined(with: .opacity))
            .animation(.spring(response: 0.30, dampingFraction: 0.84), value: complete)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(bluetooth.multiViewStatus)
        }
    }

    private func enrollmentRing(
        progress: Double,
        complete: Bool,
        remaining: Int,
        activeColor: Color
    ) -> some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.58))
                .frame(width: 176, height: 176)
                .shadow(color: .black.opacity(0.45), radius: 18)

            Circle()
                .stroke(.white.opacity(0.20), lineWidth: 8)
                .frame(width: 154, height: 154)

            Circle()
                .trim(from: 0, to: max(0.012, progress))
                .stroke(
                    complete ? Color.green : activeColor,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 154, height: 154)
                .rotationEffect(.degrees(-90))
                .shadow(color: (complete ? Color.green : activeColor).opacity(0.55), radius: 7)

            VStack(spacing: 7) {
                Image(systemName: complete ? "checkmark" : bluetooth.isRefining ? "viewfinder.circle" : bluetooth.selectedMode.icon)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(complete ? .green : .white)
                Text(complete ? "XONG" : "\(remaining)")
                    .font(.custom("Arial", size: 30).monospacedDigit().weight(.bold))
                Text(bluetooth.enrollmentStatus)
                    .font(.custom("Arial", size: 12).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 132)
            }
        }
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: complete)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bluetooth.enrollmentStatus)
    }

    private var calibrationOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(calibrationPhaseStartedAt))
            // Calibration normally takes about four seconds.  Animate locally
            // to 92%, then wait for verified stable samples before showing done.
            let localProgress = min(0.92, elapsed / 4.0 * 0.92)
            let smoothProgress = min(1, max(bluetooth.calibrationProgress, localProgress))
            calibrationRing(progress: smoothProgress)
        }
    }

    private func calibrationRing(progress: Double) -> some View {
        let complete = bluetooth.calibrationProgress >= 0.999
        return ZStack {
            Circle()
                .fill(.black.opacity(0.48))
                .frame(width: 188, height: 188)

            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 7)
                .frame(width: 164, height: 164)

            Circle()
                .trim(from: 0, to: max(0.012, progress))
                .stroke(
                    complete ? Color.green : Color.cyan,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .frame(width: 164, height: 164)
                .rotationEffect(.degrees(-90))

            Image(systemName: complete ? "checkmark" : "scope")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(complete ? .green : .white)

            VStack {
                Spacer()
                Text(bluetooth.calibrationStatus)
                    .font(.custom("Arial", size: 12).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(width: 174)
            }
            .frame(height: 236)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bluetooth.calibrationStatus)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topStatus
                .padding(.horizontal, 14)
                .padding(.top, 8)
            modeTabs
                .padding(.horizontal, 14)
                .padding(.top, 8)
            Spacer()
            bottomControls
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
    }

    private var topStatus: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(bluetooth.isConnected ? Color.green.opacity(0.22) : Color.orange.opacity(0.22))
                        .frame(width: 38, height: 38)
                    Image(systemName: "airplane.departure")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(bluetooth.isConnected ? .green : .orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("SE • \(bluetooth.selectedMode.title)")
                        .font(.custom("Arial", size: 15).weight(.bold))
                    Text(bluetooth.connectionText)
                        .font(.custom("Arial", size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showingProfiles = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.crop.rectangle.stack.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.10), in: Circle())
                        if !bluetooth.savedProfiles.isEmpty {
                            Text("\(bluetooth.savedProfiles.count)")
                                .font(.custom("Arial", size: 9).weight(.bold))
                                .foregroundStyle(.black)
                                .frame(width: 15, height: 15)
                                .background(.orange, in: Circle())
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hai mẫu tracking đã lưu")
                if camera.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(recordingTime)
                            .font(.custom("Arial", size: 14).monospacedDigit().weight(.bold))
                    }
                } else {
                    Text("0,5× cố định • 1080p60 mát máy")
                        .font(.custom("Arial", size: 13).weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }

            HStack(spacing: 9) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                Text(bluetooth.trackingTitle)
                    .font(.custom("Arial", size: 13).weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if bluetooth.trackingState == .lock || bluetooth.trackingState == .search {
                    Text("\(bluetooth.confidence)%")
                        .font(.custom("Arial", size: 14).monospacedDigit().weight(.bold))
                        .foregroundStyle(stateColor)
                }
                Text("P \(Int(bluetooth.panAngle))°  T \(Int(bluetooth.tiltAngle))°")
                    .font(.custom("Arial", size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 8) {
            ForEach(TrackingMode.allCases) { mode in
            let selected = bluetooth.selectedMode == mode
            let sessionActive = camera.isRecording || bluetooth.isSessionActive
            Button {
                    if sessionActive {
                        bluetooth.stop()
                        camera.stopRecording()
                    }
                    bluetooth.selectMode(mode)
                } label: {
                    Group {
                        if mode.rawValue == TrackingMode.waterRocket.rawValue {
                            Image("WaterRocketTabIcon")
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: mode.icon)
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                        .foregroundStyle(selected ? .black : .white.opacity(0.76))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            selected ? stateColor : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(selected ? 0.42 : 0.10), lineWidth: 1)
                        }
                        .accessibilityLabel(mode.title)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private var bottomControls: some View {
        let sessionActive = camera.isRecording || bluetooth.isSessionActive
        return VStack(spacing: 13) {
            Text(bottomStatusText)
                .font(.custom("Arial", size: 13).weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.44), in: Capsule())

            HStack(alignment: .center) {
                Button {
                    if camera.isRecording {
                        camera.stopRecording()
                    }
                    bluetooth.home()
                    camera.announceHome()
                } label: {
                    controlButton(icon: "house.fill", title: "Home", color: .blue)
                }

                Spacer()

                Button {
                    if sessionActive {
                        bluetooth.stop()
                        camera.stopRecording()
                    } else {
                        bluetooth.arm()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.92), lineWidth: 5)
                            .frame(width: 82, height: 82)
                        RoundedRectangle(cornerRadius: sessionActive ? 8 : 32, style: .continuous)
                            .fill(sessionActive ? Color.red : Color.white)
                            .frame(width: sessionActive ? 34 : 64, height: sessionActive ? 34 : 64)
                            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: sessionActive)
                    }
                }
                .disabled(!camera.isReady || (!sessionActive && !bluetooth.isConnected))
                .opacity(camera.isReady && (sessionActive || bluetooth.isConnected) ? 1 : 0.42)

                Spacer()

                Button {
                    bluetooth.calibrateCenter()
                } label: {
                    controlButton(icon: "scope", title: "Căn tâm", color: .cyan)
                }
                .buttonStyle(.plain)
                .disabled(!bluetooth.canCalibrateCenter)
                .opacity(bluetooth.canCalibrateCenter ? 1 : 0.38)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var bottomStatusText: String {
        guard bluetooth.isSessionActive, !camera.isRecording else {
            return camera.statusText
        }
        if bluetooth.isCalibrating || bluetooth.isRefining {
            return bluetooth.activeProfileSlot == nil
                ? "Đang căn tâm • chưa lưu video"
                : "Đang căn tâm + học thêm 3 giây • chưa lưu video"
        }
        if bluetooth.isProfileLoading {
            return "Đang mở mẫu đã lưu trên MaixCAM • chưa lưu video"
        }
        if bluetooth.isMultiViewCapturing {
            return "Xoay/nghiêng vật 3 giây • chưa lưu video"
        }
        if bluetooth.needsCenterCalibration {
            return "Đưa vật vào dấu + rồi bấm Căn tâm • chưa lưu video"
        }
        if bluetooth.isChoosingTarget {
            return "Chạm chọn vật cần bám • chưa lưu video"
        }
        return "Đang quét 3 giây • chưa lưu video"
    }

    @ViewBuilder
    private func trackingOverlay(in size: CGSize) -> some View {
        let point = CGPoint(
            x: size.width * bluetooth.targetX,
            y: size.height * bluetooth.targetY
        )
        // Before centre calibration show only the iPhone '+'; do not draw a
        // second square that looks like a target the user must fit into.
        let locked = bluetooth.trackingState == .lock && !bluetooth.needsCenterCalibration
        let searching = bluetooth.trackingState == .search
        // iPhone 15 renders roughly 6 logical points per millimetre.  A fixed
        // 30 pt reticle is therefore about 5 mm and shows the actual aim point;
        // the larger detector box remains internal to MaixCAM.
        let aimBoxSide: CGFloat = 30

        ZStack {
            Path { path in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                path.move(to: CGPoint(x: center.x - 14, y: center.y))
                path.addLine(to: CGPoint(x: center.x + 14, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - 14))
                path.addLine(to: CGPoint(x: center.x, y: center.y + 14))
            }
            .stroke(.white.opacity(0.48), lineWidth: 1)

            if locked || searching {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(stateColor, style: StrokeStyle(lineWidth: 2.5, dash: searching ? [7, 5] : []))
                    .frame(width: aimBoxSide, height: aimBoxSide)
                    .position(point)
                    .shadow(color: stateColor.opacity(0.48), radius: 6)
                    // ESP32 publishes at 20 Hz.  A 65 ms linear bridge removes
                    // visible stepping without adding the sluggish 100+ ms lag
                    // that makes a fast rocket appear behind the reticle.
                    .animation(.linear(duration: 0.065), value: point)

                Text("MaixCAM • \(bluetooth.lockedTargetName)")
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(stateColor.opacity(0.86), in: Capsule())
                    .position(
                        x: min(size.width - 78, max(78, point.x)),
                        y: max(32, point.y - aimBoxSide / 2 - 18)
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func candidateSelectionOverlay(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        bluetooth.selectCandidate(
                            atX: Double(min(1, max(0, value.location.x / max(1, size.width)))),
                            y: Double(min(1, max(0, value.location.y / max(1, size.height))))
                        )
                    }
                )

            ForEach(bluetooth.candidates) { candidate in
                let isPending = bluetooth.selectedCandidateID == candidate.id
                let point = CGPoint(
                    x: min(size.width - 30, max(30, size.width * candidate.x)),
                    y: min(size.height - 40, max(40, size.height * candidate.y))
                )
                let visibleWidth = min(180, max(38, size.width * candidate.width))
                let visibleHeight = min(220, max(38, size.height * candidate.height))
                let tapWidth = max(58, visibleWidth)
                let tapHeight = max(58, visibleHeight)

                Button {
                    bluetooth.selectCandidate(candidate)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                isPending ? Color.green : Color.cyan,
                                style: StrokeStyle(
                                    lineWidth: isPending ? 4 : 3,
                                    dash: isPending ? [] : [8, 4]
                                )
                            )
                            .frame(width: visibleWidth, height: visibleHeight)
                            .shadow(
                                color: (isPending ? Color.green : Color.cyan).opacity(0.72),
                                radius: 7
                            )

                        Text(isPending
                             ? "ĐANG XÁC NHẬN Ô \(candidate.id)"
                             : "\(candidate.label) • \(candidate.confidence)%")
                            .font(.custom("Arial", size: 11).weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isPending ? Color.green : Color.cyan, in: Capsule())
                            .offset(y: -visibleHeight / 2 - 17)
                    }
                    .frame(width: tapWidth, height: tapHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(bluetooth.isConfirmingCandidate || !bluetooth.isCandidateListReady)
                .position(point)
                .accessibilityLabel("Chọn \(candidate.label), độ tin cậy \(candidate.confidence) phần trăm")
            }

            VStack {
                Spacer()
                VStack(spacing: 9) {
                    Label {
                        Text(
                            bluetooth.candidates.isEmpty
                                ? "Không có ô AI • chạm trực tiếp lên vật"
                                : !bluetooth.isCandidateListReady
                                    ? "Đang nhận đủ \(bluetooth.candidates.count)/\(bluetooth.expectedCandidateCount) vật"
                                : bluetooth.isConfirmingCandidate
                                    ? "Đang xác nhận đúng ô với MaixCAM"
                                    : "Chạm trực tiếp vào vật cần theo dõi"
                        )
                    } icon: {
                        Image(systemName: bluetooth.candidates.isEmpty
                              ? "ellipsis"
                              : bluetooth.isConfirmingCandidate
                                  ? "checkmark.circle"
                                  : "hand.tap.fill")
                    }
                        .font(.custom("Arial", size: 13).weight(.bold))
                        .foregroundStyle(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9) {
                            ForEach(bluetooth.candidates) { candidate in
                                let isPending = bluetooth.selectedCandidateID == candidate.id
                                Button {
                                    bluetooth.selectCandidate(candidate)
                                } label: {
                                    HStack(spacing: 7) {
                                        Text("\(candidate.id)")
                                            .font(.custom("Arial", size: 13).weight(.black))
                                            .frame(width: 25, height: 25)
                                            .background(
                                                isPending ? Color.green : Color.cyan,
                                                in: RoundedRectangle(cornerRadius: 7)
                                            )
                                            .foregroundStyle(.black)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(candidate.label)
                                                .font(.custom("Arial", size: 12).weight(.bold))
                                            Text("Độ tin cậy \(candidate.confidence)%")
                                                .font(.custom("Arial", size: 10))
                                                .foregroundStyle(.white.opacity(0.68))
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 13)
                                            .stroke(.cyan.opacity(0.72), lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(bluetooth.isConfirmingCandidate || !bluetooth.isCandidateListReady)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
                .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 12)
                .padding(.bottom, 150)
            }
        }
        .transition(.opacity)
    }

    private func controlButton(icon: String, title: String, color: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(color.opacity(0.20)).frame(width: 46, height: 46)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.custom("Arial", size: 11).weight(.bold))
                .foregroundStyle(.white.opacity(0.76))
        }
        .frame(width: 62)
    }

    private var stateColor: Color {
        switch bluetooth.trackingState {
        case .lock: return .green
        case .search, .acquire: return .yellow
        case .choose: return .cyan
        case .refine: return .mint
        case .multiView: return .purple
        case .home: return .blue
        case .calibrate: return .cyan
        case .disconnected: return .orange
        case .idle: return .white
        }
    }

    private var stateIcon: String {
        switch bluetooth.trackingState {
        case .lock: return "scope"
        case .search: return "location.magnifyingglass"
        case .acquire: return "dot.scope"
        case .choose: return "hand.tap.fill"
        case .refine: return "viewfinder.circle"
        case .multiView: return "move.3d"
        case .home: return "house.fill"
        case .calibrate: return "scope"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .idle: return "checkmark.circle.fill"
        }
    }

    private var recordingTime: String {
        String(format: "%02d:%02d", camera.elapsedSeconds / 60, camera.elapsedSeconds % 60)
    }
}
