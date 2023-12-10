#!/bin/bash
#
# focustest.sh - Automated camera focus precision tester

set -u

# misc constants
True=1
False=0

# user parameters
focusCheckDir="/mnt/hgfs/downloads/temp/ZFocusCheck"
exiftool=~/exiftool/exiftool    # set to just "exiftool" to use the version in the system path
gphoto2=gphoto2                 # set to just "gphoto2" to use the version in the system path
mtf_mapper=mtf_mapper           # set to just "mtf_mapper" to use the version in the system path

# internal parameters
tmpdir="/tmp"
tmpShotFilename="${tmpdir}/tempFocusShiftShot"
rack_focus_wait_time_secs=2
af_wait_time_secs=3

#
# methods
#
gphoto2Exec() { # gphoto2Exec(args...)
    local args=("$@")
    retVal=$($gphoto2 --quiet ${args[@]} 2>&1) 
}
exiftoolExec() { # exiftoolExec(args...)
    local args=("$@")
    retVal=$($exiftool ${args[@]})
}
getExifTag() { # getExifTag(filename, tagname)
    local filename=$1
    local exifTag=$2
    exiftoolExec "-s3 -$exifTag $filename" 
}
setFocus() { # setFocus(value)
    gphoto2Exec --set-config manualfocusdrive=$1
}
setFocusRackedInfinity() { # setFocusRackedInfinity()
    # note: we expect an error because we're using a known-too-large increment to force to infinity
    setFocus 30000; sleep $rack_focus_wait_time_secs
}
setFocusRackedMFD() { # setFocusRackedMFD()
    # note: we expect an error because we're using a known-too-large decrement to force to MFD 
    setFocus -30000; sleep $rack_focus_wait_time_secs
}
doAutoFocus() { # doAutoFocus()
    gphoto2Exec --set-config autofocusdrive=1; sleep $af_wait_time_secs
}
takePhoto() { # takePhoto(filename)
    local filename=$1
    gphoto2Exec --set-config capturetarget=0 --capture-image-and-download --filename="$filename" --force-overwrite
}
takeTempPhoto() { # takeTempPhoto()
    local filename=$tmpShotFilename
    rm -rf "$filename"
    takePhoto "$filename"
    retVal="$filename"
}
takeTempPhotoAndGetLensPosition() { # takeTempPhotoAndGetLensPosition()
    takeTempPhoto
    getExifTag $retVal "LensPositionAbsolute";
}
stdev() { # stdev(array)
    local vals=("$@")
    # https://stackoverflow.com/a/15101429
    retVal=$(printf "%s\n" ${vals[@]} | awk '{sum+=$1; sumsq+=$1*$1}END{print sqrt(sumsq/NR - (sum/NR)**2)}')
}
mean() { # mean(array)
    local vals=("$@")
    retVal=$(printf "%s\n" ${vals[@]} | awk '{sum+=$1; sumsq+=$1*$1}END{print (sum/NR)}')
}

calcMTF() { # calcMTF(filename, coordinateString)
    local inputFilename="$1"
    local coordinates="$2"

    convert "$inputFilename" -crop "$coordinates" tempTarget.jpg

    if ! mtfMapperOutput=$($mtf_mapper -r tempTarget.jpg .); then
        echo "*** mtf_mapper reported error"
        echo "$mtfMapperOutput"
        exit 1
    fi
    mtf=$(echo "$mtfMapperOutput" | grep "Statistics on all edges" | cut -b 50-55)
    retVal="$mtf"
}
nop() { # nop()
    :
}


doFocusTestSeq() { #doFocusTestSeq(numShots, testName, rackFocusFunc, setFocusFunc, setFocusFunc_Arg)

    local numShots=$1
    local testName="$2"
    local rackFocusFunc="$3"
    local setFocusFunc="$4"
    local setFocusFunc_Arg="$5"

    echo "*** Performing test: \"${testName}\""
    setDir="${focusCheckDir}/${testName}"
    mkdir "$setDir"
    declare -a mtfsTarget
    declare -a mtfsBehindTarget
    for ((i=0; i<$numShots; i++ )); do
        if [[ "$rackFocusFunc" != "nop" ]] || [[ "$setFocusFunc" != "nop" ]]; then
            echo -n "Racking focus..."; $rackFocusFunc; echo -n "Focusing..."; $setFocusFunc $setFocusFunc_Arg
        fi
        printf -v fileName "${setDir}/${testName}_%03d_of_%03d.jpg" $((i+1)) $numShots
        echo -en "Taking photo $((i+1))/$numShots to $fileName..."; takePhoto "$fileName";
        echo -ne "\r"
        echo

        #
        # I set up two MTF targets - the main target we measure MTF, and one just
        # behind it. the purpose of the second is to measure if AF misses are
        # back or front-focused - I don't currently report this secondary measure
        #

        # hard-coded coordinates for target on my setup - yuck, need to make more generic
        calcMTF "$fileName" "855x1278+3030+1000"
        mtfsTarget+=("$retVal")
        calcMTF "$fileName" "866x1206+4160+1217"
        mtfsBehindTarget+=("$retVal")
    done
    echo

    # do summary absolute ending lens position calculations (native Z lenses only)
    lensPositions=($($exiftool -LensPositionAbsolute -s3 -q ${setDir}))
    if (( ${#lensPositions[@]} )); then
        echo    "Lens Positions: ${lensPositions[@]}"
        stdev   "${lensPositions[@]}"; resultStdev=$retVal
        mean    "${lensPositions[@]}"; resultMean=$retVal
        resultCov=$(echo "${resultStdev}/${resultMean}*100" | bc -l | awk '{printf "%.4f", $0}')
        echo "Stdev: $resultStdev, Mean: $resultMean, COV: $resultCov%"
        echo
    fi

    # do summary MTF calculations
    echo    "MTFs: ${mtfsTarget[@]}"
    stdev   "${mtfsTarget[@]}"; resultStdev=$retVal
    mean    "${mtfsTarget[@]}"; resultMean=$retVal
    resultCov=$(echo "${resultStdev}/${resultMean}*100" | bc -l | awk '{printf "%.4f", $0}')
    echo "Stdev: $resultStdev, Mean: $resultMean, COV: $resultCov%"

    echo
}

#
#############################################################################
#
# script functional starting point 
#

#
# routines that automate focus position of critical focus on native Z lenses
# using AF and the absolute lens position reported in EXIF
#
fCalcLensStepsFromReportedLensPos=$False
if [[ fCalcLensStepsFromReportedLensPos -eq $True ]]; then
    echo -n "Racking focus to Infinity..."; setFocusRackedInfinity
    echo -n "Taking photo..."; takeTempPhotoAndGetLensPosition; lensPosInfnity=$retVal
    echo "Lens position at infinity: ${lensPosInfnity}"

    echo -n "Racking focus to MFD..."; setFocusRackedMFD
    echo -n "Taking photo..."; takeTempPhotoAndGetLensPosition; lensPosMFD=$retVal
    echo "Lens position at MFD: ${lensPosMFD}"

    read -sp "**** Set critical focus. Press enter when done... "; echo
    echo -n "Taking photo to get lens pos..."; takeTempPhotoAndGetLensPosition; expectedLensPos=$retVal
    echo "Lens position for critical focus: $expectedLensPos"

    # lens steps from MFD -> focus point are +positive (MFD is lowest number, Infinity is highest)
    # lens steps from Infinity -> focus point are -negative
    lensStepsToFocusFromMFD=$((lensPosMFD - expectedLensPos))
    lensStepsToFocusFromInfinity=$((expectedLensPos - lensPosInfnity))
else
    #
    # hard-coded critical focus position found manually outside of script before running
    #

    # Z-Mount 50mm f/1.8S
    lensStepsToFocusFromMFD=710
    lensStepsToFocusFromInfinity=-1337

    # F-Mount 50mm f/1.8G
    #lensStepsToFocusFromMFD=1280
    #lensStepsToFocusFromInfinity=-2950
fi

numShots=50

rm -rf "${focusCheckDir}"/*

# measure shot-shot MTF variance on fixed focus (ex: image noise)
doAutoFocus; doFocusTestSeq 10 "FixedFocus"  nop nop 0

# measure MFD -> focus position in one lens movement
doFocusTestSeq $numShots "MFD_To_Pos"  setFocusRackedMFD setFocus $lensStepsToFocusFromMFD

# measure Infinity -> focus position in one lens movement
doFocusTestSeq $numShots "Infinity_To_Pos"  setFocusRackedInfinity setFocus $lensStepsToFocusFromInfinity

# measure MFD -> focus position via AF
doFocusTestSeq $numShots "MFD_To_AF"  setFocusRackedMFD doAutoFocus 0

# measure Infinity -> focus position via AF
doFocusTestSeq $numShots "Infinity_To_AF"  setFocusRackedInfinity doAutoFocus 0

