import java.util.List;

class PacketRecord {
    public int numLost;
    public int numReceived;

    PacketRecord(int _numLost, int _numReceived) {
        numLost = _numLost;
        numReceived = _numReceived;
    }

    public int getNumExpected() {
        return numLost + numReceived;
    }

    public float getLostPercent() {
        if(getNumExpected() == 0) {
            return 0.f;
        }

        return numLost * 100.f / getNumExpected();
    }

    public void appendAll(List<PacketRecord> toAppend) {
        for (PacketRecord record : toAppend) {
            numLost += record.numLost;
            numReceived += record.numReceived;
        }
    }
}

class PacketLossTracker {

    public boolean silent = false;

    private int sampleIndexChannel;
    private int timestampChannel;
    private double[] lastSample = null;
    private int lastSampleIndexLocation;
    private boolean newStream = false;

    private PacketRecord sessionPacketRecord = new PacketRecord(0, 0);
    private PacketRecord streamPacketRecord = new PacketRecord(0, 0);

    private TimeTrackingQueue<PacketRecord> packetRecords;

    protected ArrayList<Integer> sampleIndexArray = new ArrayList<Integer>();

    // use these vars for notification at the bottom
    private boolean notificationShown = false;
    protected String lostPackagesMsg = "Lost packets detected, open packet loss widget for more info";
    protected String noLostPackagesMsg = "Data streaming is running as usual";
    protected int windowSizeNotificationMs = 5000;
    protected double thresholdNotification = 1.0;

    PacketLossTracker(int _sampleIndexChannel, int _timestampChannel, int _minSampleIndex, int _maxSampleIndex) {        
        this(_sampleIndexChannel, _timestampChannel,  _minSampleIndex, _maxSampleIndex, new RealTimeProvider());
    }

    PacketLossTracker(int _sampleIndexChannel, int _timestampChannel, int _minSampleIndex, int _maxSampleIndex, TTQTimeProvider _timeProvider) {        
        this(_sampleIndexChannel, _timestampChannel, _timeProvider);

        // add indices to array of indices
        for (int i = _minSampleIndex; i <= _maxSampleIndex; i++) {
            sampleIndexArray.add(i);
        }
    }

    PacketLossTracker(int _sampleIndexChannel, int _timestampChannel, TTQTimeProvider _timeProvider) {
        packetRecords = new TimeTrackingQueue<PacketRecord>(60 * 1000, _timeProvider);
        sampleIndexChannel = _sampleIndexChannel;
        timestampChannel = _timestampChannel;
    }

    public void onStreamStart() {
        streamPacketRecord.numLost = 0;
        streamPacketRecord.numReceived = 0;
        newStream = true;
        reset();
    }

    public PacketRecord getSessionPacketRecord() {
        return sessionPacketRecord;
    }

    public PacketRecord getStreamPacketRecord() {
        return streamPacketRecord;
    }

    public List<PacketRecord> getAllPacketRecordsForLast(int milliseconds) {
        return packetRecords.getLastData(milliseconds);
    }

    public PacketRecord getCumulativePacketRecordForLast(int milliseconds) {
        List<PacketRecord> allRecords = getAllPacketRecordsForLast(milliseconds);
        PacketRecord result = new PacketRecord(0, 0);
        result.appendAll(allRecords);
        return result;
    }

    public void addSamples(List<double[]> newSamples) {
        sessionPacketRecord.numReceived += newSamples.size();
        streamPacketRecord.numReceived += newSamples.size();

        // create packet record for this call, add received count.
        // loss count will be added in the for loop
        PacketRecord currentRecord = new PacketRecord(0, newSamples.size());

        for (double[] sample : newSamples) {
            int currentSampleIndex = (int)(sample[sampleIndexChannel]);
            
            // handle new stream start
            if (newStream) {
                // wait until we restart the sample index array. this handles the case
                // of starting a new stream and there are still samples from the
                // previous stream in the serial buffer
                if (currentSampleIndex == sampleIndexArray.get(0)) {
                    lastSample = sample;
                    lastSampleIndexLocation = 0;
                    newStream = false;
                }
                continue;
            }

            // handle first call
            if (lastSample == null) {
                lastSample = sample;
                lastSampleIndexLocation = sampleIndexArray.indexOf(currentSampleIndex);
                continue;
            }

            incrementLastSampleIndexLocation();

            int numSamplesLost = 0;

            while (sampleIndexArray.get(lastSampleIndexLocation) != currentSampleIndex) {
                incrementLastSampleIndexLocation();
                numSamplesLost++;

                if (numSamplesLost > sampleIndexArray.size()) {
                    // we looped the entire array, the new sample is not part of the current array
                    println("WARNING: The sample index " + currentSampleIndex + " is not in the list of possible sample indices.");
                    break;
                }
            }

            if (numSamplesLost > 0) {
                sessionPacketRecord.numLost += numSamplesLost;
                streamPacketRecord.numLost += numSamplesLost;
                currentRecord.numLost += numSamplesLost;

                if(!silent) {
                    // print the packet loss event
                    println("WARNING: Lost " + numSamplesLost + " Samples Between "
                        +  (int)lastSample[sampleIndexChannel] + "-" + (int)sample[sampleIndexChannel]);
                }
            }

            lastSample = sample;
        }

        packetRecords.push(currentRecord);
        checkCurrentStreamStatus();
    }

    private void incrementLastSampleIndexLocation() {
        // increment index location, advance through list of indexes
        // make sure to loop around if we reach the end of the list
        lastSampleIndexLocation ++;
        lastSampleIndexLocation = lastSampleIndexLocation % sampleIndexArray.size();
    }

    protected void reset() {
        lastSample = null;
    }

    protected void checkCurrentStreamStatus() {
        PacketRecord lastMillisPacketRecord = getCumulativePacketRecordForLast(windowSizeNotificationMs);
        if (lastMillisPacketRecord.getLostPercent() > thresholdNotification) {
            if (!notificationShown) {
                notificationShown = true;
                outputWarn(lostPackagesMsg);
            }
        }
        else {
            if (notificationShown) {
                notificationShown = false;
                outputInfo(noLostPackagesMsg);
            }
        }
    }
}

// sample index range 1-255, odd numbers only (skips evens)
class PacketLossTrackerCytonSerialDaisy extends PacketLossTracker {

    PacketLossTrackerCytonSerialDaisy(int _sampleIndexChannel, int _timestampChannel) {
        this(_sampleIndexChannel, _timestampChannel, new RealTimeProvider());
    }

    PacketLossTrackerCytonSerialDaisy(int _sampleIndexChannel, int _timestampChannel, TTQTimeProvider _timeProvider) {
        super(_sampleIndexChannel, _timestampChannel, _timeProvider);

        // add indices to array of indices
        // 0-254, event numbers only (skips odds)
        int firstIndex = 0;
        int lastIndex = 254;
        for (int i = firstIndex; i <= lastIndex; i += 2) {
            sampleIndexArray.add(i);
        }
    }
}

class PacketLossTrackerGanglionBLE extends PacketLossTracker {

    ArrayList<Integer> sampleIndexArrayAccel = new ArrayList<Integer>();
    ArrayList<Integer> sampleIndexArrayNoAccel = new ArrayList<Integer>();

    PacketLossTrackerGanglionBLE(int _sampleIndexChannel, int _timestampChannel) {
        this(_sampleIndexChannel, _timestampChannel, new RealTimeProvider());
    }

    PacketLossTrackerGanglionBLE(int _sampleIndexChannel, int _timestampChannel, TTQTimeProvider _timeProvider) {
        super(_sampleIndexChannel, _timestampChannel, _timeProvider);
    }

    public void setAccelerometerActive(boolean active) {
        // choose correct array based on wether accel is active or not
        if (active) {
            sampleIndexArray = sampleIndexArrayAccel;
        }
        else {
            sampleIndexArray = sampleIndexArrayNoAccel;
        }

        reset();
    }
}

// With acceleration: sample index range 0-100, all sample indexes are duplicated except for zero.
// E.g. 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, ... , 99, 99, 100, 100, 0, 1, 1, 2, 2, 3, 3, ...
// Without acceleration: sample 0, then 101-200
class PacketLossTrackerGanglionBLE2 extends PacketLossTrackerGanglionBLE {
    PacketLossTrackerGanglionBLE2(int _sampleIndexChannel, int _timestampChannel) {
        this(_sampleIndexChannel, _timestampChannel, new RealTimeProvider());
    }

    PacketLossTrackerGanglionBLE2(int _sampleIndexChannel, int _timestampChannel, TTQTimeProvider _timeProvider) {
        super(_sampleIndexChannel, _timestampChannel, _timeProvider);

        // Add indices to array of indices
        // With acceleration: 0-100, all sample indexes are duplicated except for zero
        sampleIndexArrayAccel.add(0);
        for (int i = 1; i <= 100; i++) {
            sampleIndexArrayAccel.add(i);
            sampleIndexArrayAccel.add(i);
        }

        // Add indices to array of indices
        // Without acceleration: 0, then 101 to 200, all sample indexes are duplicated except for zero
        sampleIndexArrayNoAccel.add(0);
        for (int i = 101; i <= 200; i++) {
            sampleIndexArrayNoAccel.add(i);
            sampleIndexArrayNoAccel.add(i);
        }

        setAccelerometerActive(true);
    }
}

// With acceleration: sample index range 0-100, all sample indexes are duplicated (including zero).
// E.g. 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, ... , 99, 99, 100, 100, 0, 0, 1, 1, 2, 2, 3, 3, ...
// Without acceleration: 101-200
class PacketLossTrackerGanglionBLE3 extends PacketLossTrackerGanglionBLE {
    PacketLossTrackerGanglionBLE3(int _sampleIndexChannel, int _timestampChannel) {
        this(_sampleIndexChannel, _timestampChannel, new RealTimeProvider());
    }

    PacketLossTrackerGanglionBLE3(int _sampleIndexChannel, int _timestampChannel, TTQTimeProvider _timeProvider) {
        super(_sampleIndexChannel, _timestampChannel, _timeProvider);

        for (int i = 0; i < 100; i++) {
            sampleIndexArrayAccel.add(i);
            sampleIndexArrayAccel.add(i);
        }

        for (int i = 100; i < 200; i++) {
            sampleIndexArrayNoAccel.add(i);
            sampleIndexArrayNoAccel.add(i);
        }

        setAccelerometerActive(true);
    }
}