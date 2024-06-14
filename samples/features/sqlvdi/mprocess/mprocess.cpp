/***********************************************************************
Copyright (c) Microsoft Corporation
All Rights Reserved.
***********************************************************************/
// This source code is an intended supplement to the Microsoft SQL
// Server online references and related electronic documentation.
//
// This sample is for instructional purposes only.
// Code contained herein is not intended to be used "as is" in real applications.
// 
// mprocess.cpp :
//  
//  Test & demonstrate the use of multiple streams where each stream is
//  handled by a secondary process.
//
// This is a sample program used to demonstrate the Virtual Device Interface
// feature of Microsoft SQL Server.
//
// The program will backup or restore the 'pubs' sample database.
//
// The program requires two command line parameters.  
// 1)
// One of:
//  b   perform a backup
//  r   perform a restore
//
//  s   Act as a secondary client  (used internally only)
//
// 2)
// If b or r is given, then a second parm gives the number of streams to use,
// (1-32).
// The secondary processes are invoked automatically, and the second parm is the
// stream id (0..31), the third parm the VDSName.
//  

#define _WIN32_DCOM

#include <objbase.h>    // for 'CoInitialize()'
#include <stdio.h>      // for file operations
#include <ctype.h>      // for toupper ()
#include <windows.h>

#include "vdi.h"        // interface declaration
#include "vdierror.h"   // error constants
#include "vdiguid.h"    // define the GUIDs 

void LogError (
    LPSTR           location,    // must always be provided
    LPSTR           description, // NULL is acceptable
    DWORD           errCode);    // windows status code

int performTransfer (
    IClientVirtualDevice*   vd,
    int                     backup,
    int                     streamId);

HANDLE execSQL (int doBackup, int nStreams);

int
runSecondary (int streamId, IClientVirtualDeviceSet *vds);

int
startSecondaries(
    IClientVirtualDeviceSet *vds,
    HANDLE  hSQLProcess,  // handle to process dealing with the SQL
    int     nStreams,     // number of i/o streams
    char*   pgmName);    // the name of this program

// Using a GUID for the VDS Name is a good way to assure uniqueness.
//
WCHAR	wVdsName [100];


//
// main function
//
int main(int argc, char *argv[])
{
    HRESULT                     hr;
    IClientVirtualDeviceSet*    vds = NULL ; 
    VDConfig                    config;
    int                         badParm=TRUE;
    int                         doBackup;
    HANDLE                      hProcess;
    int                         termCode = -1;
    int                         nStreams=1;
    int                         isSecondary = FALSE;

    // Check the input parm
    //
    if (argc >= 3)
    {
        sscanf (argv[2], "%d", &nStreams);
        switch (toupper(argv[1][0]))
        {
            case 'B':
                doBackup = TRUE;
                badParm = FALSE;
                break;
        
            case 'R':
                doBackup = FALSE;
                badParm = FALSE;
                break;

            case 'S':
                doBackup = FALSE; // we don't know or care
                badParm = FALSE;
                isSecondary = TRUE;
                // nStreams is the streamid!
		        swprintf (wVdsName, L"%hs", argv[3]);
                break;
        }
    }

    if (badParm)
    {
        printf ("useage: mprocess {B|R} <nStreams>\n"
            "Demonstrate a multistream Backup or Restore using the Virtual Device Interface\n");
        exit (1);
    }

    if (isSecondary)
    {
        printf("Secondary pid %d working on stream %d\n", GetCurrentProcessId (), nStreams);
    }
    else
    {
        // 1..32 streams.
        //
        if (nStreams < 1)
            nStreams = 1;
        else if (nStreams > 32)
            nStreams = 32;

        printf ("Performing a %s using %d virtual device(s).\n", 
            (doBackup) ? "BACKUP" : "RESTORE", nStreams);
    }

    // Initialize COM Library
    // Note: _WIN32_DCOM must be defined during the compile.
    //
    hr = CoInitializeEx (NULL, COINIT_MULTITHREADED);

    if (!SUCCEEDED (hr))
    {
        printf ("Coinit fails: x%X\n", hr);
        exit (1);
    }


    // Get an interface to the device set.
    // Notice how we use a single IID for both the class and interface
    // identifiers.
    //
    hr = CoCreateInstance ( 
        IID_IClientVirtualDeviceSet,
        NULL, 
        CLSCTX_INPROC_SERVER,
        IID_IClientVirtualDeviceSet,
        (void**)&vds);

    if (!SUCCEEDED (hr))
    {
        // This failure might happen if the DLL was not registered.
        //
        printf ("Could not create component: x%X\n", hr);
        printf ("Check registration of SQLVDI.DLL and value of IID\n");
        goto exit;
    }

    // Perform secondary processing, if this is a 
    // secondary process.
    //
    if (isSecondary)
    {
        termCode = runSecondary (nStreams, vds);

        goto exit;
    }

    // The following logic is executed by the primary process.
    //

    // Setup the VDI configuration we want to use.
    // This program doesn't use any fancy features, so the
    // only field to setup is the deviceCount.
    //
    // The server will treat the virtual device just like a pipe:
    // I/O will be strictly sequential with only the basic commands.
    //
    memset (&config, 0, sizeof(config));

    config.deviceCount = nStreams;

	// Create a GUID to use for a unique virtual device name
	//
	GUID	vdsId;
	CoCreateGuid (&vdsId);
	StringFromGUID2 (vdsId, wVdsName, 49);

    // Create the virtual device set
    //
    hr = vds->Create (wVdsName, &config);
    if (!SUCCEEDED (hr))
    {
        printf ("VDS::Create fails: x%X", hr);
        goto exit;
    }

    // Send the SQL command, via isql in a subprocess.
    //
    printf("\nSending the SQL...\n");

    hProcess = execSQL (doBackup, nStreams);
    if (hProcess == NULL)
    {
        printf ("execSQL failed.\n");
        goto shutdown;
    }


    // Wait for the server to connect, completing the configuration.
    // Notice that we wait a maximum of 15 seconds.
    //
    printf("\nWaiting for SQL to complete configuration...\n");

    hr = vds->GetConfiguration (15000, &config);
    if (!SUCCEEDED (hr))
    {
        printf ("VDS::Getconfig fails: x%X\n", hr);
        goto shutdown;
    }

    // Handle the virtual devices in secondary processes.
    //
    printf ("\nSpawning secondary processes...\n");
    termCode = startSecondaries (vds, hProcess, nStreams, argv[0]);
    
shutdown:

    // Close the set
    //
    vds->Close ();

    // COM reference counting: Release the interface.
    //
    vds->Release () ;

exit:

    // Uninitialize COM Library
    //
    CoUninitialize () ;

    return termCode;
}

//
// Execute a basic backup/restore, by starting 'osql' in a subprocess.
//
// Returns:
//  NULL    : failed to start isql
//  else    : process handle
//
HANDLE execSQL (int doBackup, int nStreams)
{
    char                    cmd[5000];
    char                    extend[100];
    PROCESS_INFORMATION     pi;
    STARTUPINFO             si;
    int                     ix;

    // Build the SQL, submitting it via 'isql'
    // If you want to use Windows NT Authentication, please do not use the -U or -P options.
    sprintf (cmd, 
        "osql -E -b -Q\"%s DATABASE PUBS %s VIRTUAL_DEVICE='%ls'",
        (doBackup) ? "BACKUP" : "RESTORE",
        (doBackup) ? "TO"     : "FROM",
		wVdsName);
    
    for (ix=1; ix<nStreams; ix++)
    {
        sprintf (extend, ", VIRTUAL_DEVICE='%ls%d'", wVdsName, ix);
        strcat (cmd, extend);
    }

    strcat (cmd, "\"");

    printf ("Submitting SQL:\n%s\n\n", cmd);

    // use my process for startup info
    //
    GetStartupInfo (&si);

    if (!CreateProcess (NULL, cmd, NULL, NULL,
            TRUE,   // inherit handles (stdin/stdout)
            0,      // creation flags,
            NULL, NULL,
            &si,    // startup info
            &pi))   // out: process info
    {
        LogError ("startSecondary", "CreateProcess", GetLastError ());
        return NULL;
    }
    
    // Return the process handle
    //
    return (pi.hProcess);
}

//-----------------------------------------------------------
// Invoke the secondary processes, and wait for all children
// to complete.
//
// Returns: 0 if no errors were detected.
//
//
int
startSecondaries(
    IClientVirtualDeviceSet *vds,
    HANDLE  hSQLProcess,  // handle to process dealing with the SQL
    int     nStreams,     // number of i/o streams
    char*   pgmName)      // the name of this program
{
    int ix,nActive;
    HANDLE      children[33];  // 32 is maximum number of streams.
                               // plus one for the isql process.
    DWORD   waitStatus, exitCode;
    char                    cmd[200];
    PROCESS_INFORMATION     pi;
    STARTUPINFO             si;

    // use my process for startup info
    //
    GetStartupInfo (&si);

    for (ix=0; ix<nStreams; ix++)
    {
        sprintf (cmd, "%s s %d %ls", pgmName, ix, wVdsName);

        if (!CreateProcess (NULL, cmd, NULL, NULL,
            TRUE,   // inherit handles (just stdin/stdout I hope!)
            0,      // creation flags,
            NULL, NULL,
            &si,    // startup info
            &pi))   // out: process info
        {
            printf ("Error starting %s\n", cmd);
            LogError ("startSecondary", "CreateProcess", GetLastError ());
            goto errorExit;
        }
        // keep the process handle
        children[ix] = pi.hProcess;
    }

    // Add the isql process into the array
    //
    children[nStreams] = hSQLProcess;
    nActive = nStreams+1;

    // Wait for all to finish.
    // Max wait is one minute for this tiny test.
    //
    printf ("All children are now running.\n"
        "Waiting for their completion...\n");

    // Notice how this differs from the threaded model in mthread.cpp.
    // In the multiprocess model, the primary client (running this code)
    // is responsible for detecting abnormal termination of the
    // secondary clients.
    // A simple "wait-for-all" approach may wait indefinitely if only
    // one of the secondaries was to abnormally terminate.
    //
    do
    {
        // Wait for any completion
        //
        waitStatus = WaitForMultipleObjects (nActive, children, 
            FALSE, INFINITE);

        if (waitStatus >= WAIT_OBJECT_0 &&
            waitStatus < WAIT_OBJECT_0+nActive)
        {
            // One of the children completed.
            // Determine which one.
            //
            ix = waitStatus - WAIT_OBJECT_0;

            // Check its completion code
            //
            if (!GetExitCodeProcess (children[ix], &exitCode))
            {
                LogError ("startSecondary", "GetExitCode", GetLastError ());
                goto errorExit;
            }

            if (exitCode != 0)
            {
                printf ("A child exitted with code %d\n", exitCode);
                goto errorExit;
            }

            // It is good programming practice to close handles when
            // finished with them.
            // Since this sample simply terminates the process for error
            // handling, we don't need to do it, as handles are automatically
            // closed as part of process termination.
            //
            CloseHandle (children[ix]);

            // Remove the handle for this child
            //
            memmove (&children[ix], &children[ix+1], 
                sizeof (HANDLE) * (nActive-ix-1));

            nActive--;

        }
        else
        {
            printf("Unexpected wait code: %d\n", waitStatus);
            goto errorExit;
        }

    } while (nActive > 0);

    printf ("All children completed successfully\n");

    return 0;

errorExit:
    // Handle all problems in a trivial fashion:
    //  SignalAbort() will cause all processes using the virtual device set
    //  to terminate processing.
    //  Thus, we don't bother waiting for any children to terminate.
    //
    vds->SignalAbort ();
    return -1;

}

//------------------------------------------------------------------
// Perform secondary client processing
// Return 0 if no errors detected, else nonzero.
//
int
runSecondary (int streamId, IClientVirtualDeviceSet *vds)
{
    HRESULT                         hr;
    WCHAR                           devName[100];
    IClientVirtualDevice*           vd;
    VDConfig                        config;
    int                             termCode;

    // Open the device
    //
    if (streamId == 0)
    {
        // The first device has the same name as the set.
        //
        wcscpy (devName, wVdsName);
    }
    else
    {
        // For this example, we've simply appended a number
        // for additional devices.  You are free to name them
        // as you wish.
        //
        swprintf (devName, L"%ls%d", wVdsName, streamId);
    }

    // Open the virtual device set in this secondary process.
    //
    hr = vds->OpenInSecondary (wVdsName);
    if (!SUCCEEDED (hr))
    {
        printf ("VD::Open(%ls) fails: x%X", devName, hr);
        return -1;
    }

    // Open the device assigned to this process.
    //
    hr = vds->OpenDevice (devName, &vd);
    if (!SUCCEEDED (hr))
    {
        printf ("OpenDevice fails on %ls: x%X", devName, hr);
        return -1;
    }

    // Grab the config to figure out data direction
    //
    hr = vds->GetConfiguration (INFINITE, &config);
    if (!SUCCEEDED (hr))
    {
        printf ("VDS::Getconfig fails: x%X\n", hr);
        termCode = -1;
        goto errExit;
    }

    printf ("\nPerforming data transfer...\n");
        
    termCode = performTransfer (vd, 
        (config.features&VDF_WriteMedia), streamId);

errExit:

    // If errors were detected, force an abort.
    //
    if (termCode != 0)
    {
        vds->SignalAbort ();
    }

    vds->Close ();

    return termCode;
}


// This routine reads commands from the server until a 'Close' status is received.
// It simply synchronously reads or writes a file on the root of the current drive.
//
// Returns 0, if no errors are detected, else non-zero.
//
int performTransfer (
    IClientVirtualDevice*   vd,
    int                     backup,
    int                     streamId)
{
    FILE *          fh;
    char            fname[80];
    VDC_Command *   cmd;
    DWORD           completionCode;
    DWORD           bytesTransferred;
    HRESULT         hr;
    int             termCode = -1;

    sprintf (fname, "multi.%d.dmp", streamId);

    fh = fopen (fname, (backup)? "wb" : "rb");
    if (fh == NULL )
    {
        printf ("Failed to open: %s\n", fname);
        return -1;
    }

    while (SUCCEEDED (hr=vd->GetCommand (INFINITE, &cmd)))
    {
        bytesTransferred = 0;
        switch (cmd->commandCode)
        {
            case VDC_Read:
                bytesTransferred = fread (cmd->buffer, 1, cmd->size, fh);
                if (bytesTransferred == cmd->size)
                    completionCode = ERROR_SUCCESS;
                else
                    // assume failure is eof
                    completionCode = ERROR_HANDLE_EOF;

                break;

            case VDC_Write:
                bytesTransferred = fwrite (cmd->buffer, 1, cmd->size, fh);
                if (bytesTransferred == cmd->size )
                {
                    completionCode = ERROR_SUCCESS;
                }
                else
                    // assume failure is disk full
                    completionCode = ERROR_DISK_FULL;
                break;

            case VDC_Flush:
                fflush (fh);
                completionCode = ERROR_SUCCESS;
                break;
    
            case VDC_ClearError:
                completionCode = ERROR_SUCCESS;
                break;

            default:
                // If command is unknown...
                completionCode = ERROR_NOT_SUPPORTED;
        }


        hr = vd->CompleteCommand (cmd, completionCode, bytesTransferred, 0);
        if (!SUCCEEDED (hr))
        {
            printf ("Completion Failed: x%X\n", hr);
            break;
        }
    }

    if (hr != VD_E_CLOSE)
    {
        printf ("Unexpected termination: x%X\n", hr);
    }
    else
    {
        // As far as the data transfer is concerned, no
        // errors occurred.  The code which issues the SQL
        // must determine if the backup/restore was
        // really successful.
        //
        printf ("Successfully completed data transfer.\n");
        termCode = 0;
    }

    fclose (fh);

    return termCode;
}

//--------------------------------------------------------------------
// 
// A simple error logger.
//
void LogError (
    LPSTR           location,    // must always be provided
    LPSTR           description, // NULL is acceptable
    DWORD           errCode)     // windows status code
{
    LPVOID lpMsgBuf;

    printf (
        "Error at %s: %s StatusCode: %X\n",
        location, 
        (description==NULL)?"":description,
        errCode);

    // Attempt to explain the code
    //
    if (errCode != 0 && FormatMessage(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | 
            FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,    
        NULL,
        errCode,
        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), // Default language
        (LPTSTR) &lpMsgBuf,    0,    NULL ) )// Process any inserts in lpMsgBuf.
    {
        printf ("Explanation: %s\n", lpMsgBuf);
        LocalFree( lpMsgBuf );
    }
}

