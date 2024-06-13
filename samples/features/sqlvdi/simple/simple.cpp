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
// simple.cpp
//
// This is a sample program used to demonstrate the Virtual Device Interface
// feature of Microsoft SQL Server.
//
// The program will backup or restore the 'pubs' sample database.
//
// The program accepts a single command line parameter.  
// One of:
//  b   perform a backup
//  r   perform a restore
//  


// To gain access to free threaded COM, you'll need to define _WIN32_DCOM
// before the system headers, either in the source (as in this example),
// or when invoking the compiler (by using /D "_WIN32_DCOM")
//
#define _WIN32_DCOM

#include <objbase.h>    // for 'CoInitialize()'
#include <stdio.h>      // for file operations
#include <ctype.h>      // for toupper ()
#include <process.h>    // for spawn ()

#include "vdi.h"        // interface declaration
#include "vdierror.h"   // error constants

#include "vdiguid.h"    // define the interface identifiers.
			// IMPORTANT: vdiguid.h can only be included in one source file.
			// 


void performTransfer (
    IClientVirtualDevice*   vd,
    int                     backup );

int execSQL (int doBackup);

// Using a GUID for the VDS Name is a good way to assure uniqueness.
//
WCHAR	wVdsName [50];


//
// main function
//
int main(int argc, char *argv[])
{
    HRESULT                     hr;
    IClientVirtualDeviceSet2*   vds = NULL ; 
    IClientVirtualDevice*       vd=NULL;

    VDConfig                    config;
    int                         badParm=TRUE;
    int                         doBackup;
    int                         hProcess;
    int                         termCode;

    // Check the input parm
    //
    if (argc == 2)
    {
        if (toupper(argv[1][0]) == 'B')
        {
            doBackup = TRUE;
            badParm = FALSE;
        }
        else if (toupper(argv[1][0]) == 'R')
        {
            doBackup = FALSE;
            badParm = FALSE;
        }
    }

    if (badParm)
    {
        printf ("useage: simple {B|R}\n"
            "Demonstrate a Backup or Restore using the Virtual Device Interface\n");
        exit (1);
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
    // Changes from SQLServer v7.0: 
	//    - we've introduced a symbol for the class ID.
	//    - We've added a new "multi-instance-aware" interface.
    //
    hr = CoCreateInstance ( 
        CLSID_MSSQL_ClientVirtualDeviceSet,  
	    NULL, 
	    CLSCTX_INPROC_SERVER,
	    IID_IClientVirtualDeviceSet2,
	    (void**)&vds);

    if (!SUCCEEDED (hr))
    {
        // This failure might happen if the DLL was not registered,
	// or if the application is using the wrong interface id (IID).
        //
        printf ("Could not create component: x%X\n", hr);
        printf ("Check registration of SQLVDI.DLL and value of IID\n");
        goto exit;
    }

    // Setup the VDI configuration we want to use.
    // This program doesn't use any fancy features, so the
    // only field to setup is the deviceCount.
    //
    // The server will treat the virtual device just like a pipe:
    // I/O will be strictly sequential with only the basic commands.
    //
    memset (&config, 0, sizeof(config));
    config.deviceCount = 1;

	// Create a GUID to use for a unique virtual device name
	//
	GUID	vdsId;
	CoCreateGuid (&vdsId);
	StringFromGUID2 (vdsId, wVdsName, 49);

    // Create the virtual device set
	// for use by the default instance.
    // Change the first parameter to identify a named instance.
	//
    hr = vds->CreateEx (NULL, wVdsName, &config);
    if (!SUCCEEDED (hr))
    {
        printf ("VDS::Create fails: x%X", hr);
        goto exit;
    }

    // Send the SQL command, by starting 'isql' in a subprocess.
    //
    printf("\nSending the SQL...\n");

    hProcess = execSQL (doBackup);
    if (hProcess == -1)
    {
        printf ("execSQL failed.\n");
        goto shutdown;
    }

    // Wait for the server to connect, completing the configuration.
    //
    hr = vds->GetConfiguration (10000, &config);
    if (!SUCCEEDED (hr))
    {
        printf ("VDS::Getconfig fails: x%X\n", hr);
        if (hr == VD_E_TIMEOUT)
        {
            printf ("Timed out. Was Microsoft SQLServer running?\n");
        }
        goto shutdown;
    }

    // Open the single device in the set.
    //
    hr = vds->OpenDevice (wVdsName, &vd);
    if (!SUCCEEDED(hr))
    {
        printf ("VDS::OpenDevice fails: x%X\n", hr);
        goto shutdown;
    }

    printf ("\nPerforming data transfer...\n");
    
    performTransfer (vd, doBackup);
    
    
shutdown:

    // Close the set
    //
    vds->Close ();

    // Obtain the SQL completion information, by waiting for isql to exit.
    //
    if (hProcess == _cwait( &termCode, hProcess, NULL))
    {
        if (termCode == 0)
            printf("\nThe SQL command executed successfully.\n");
        else
            printf("\nThe SQL command failed.\n");
    }
    else
    {
        printf ("cwait failed: %d\n", errno);
    }

    // COM reference counting: Release the interface.
    //
    // Rather than releasing it, the application has the
    // option to 'Create' another set, reusing the interface
    // that it currently has.  Of course that applies to 
    // a real application, not this simple sample!
    //
    vds->Release () ;

exit:

    // Uninitialize COM Library
    //
    CoUninitialize () ;

    return 0 ;
}

//
// Execute a basic backup/restore, by spawning a process to execute 'isql'.
//
// Returns:
//  -1      : failed to spawn
//  else    : a "process handle" 
//
int execSQL (int doBackup)
{
	char	sqlCommand [1024];		// plenty of space for our purpose

	sprintf (sqlCommand, "-Q\"%s DATABASE PUBS %s VIRTUAL_DEVICE='%ls'\"",
		(doBackup) ? "BACKUP" : "RESTORE",
		(doBackup) ? "TO" : "FROM",
		wVdsName);
    int rc;

	printf ("spawning osql to execute: %s\n", sqlCommand);

    // Spawn off the osql utility to execute the SQL.
    // Notice the '-b' which causes an error to set a non-zero
    // exit code on error.
	//
    rc = _spawnlp( _P_NOWAIT, "osql", "osql", "-E", "-b",
        sqlCommand, NULL);

    if (rc == -1)
    {
        printf ("Spawn failed with error: %d\n", errno);
    }
    
    return (rc);
}

// This routine reads commands from the server until a 'Close' status is received.
// It simply reads or writes a file 'superbak.dmp' in the current directory.
//
void performTransfer (
    IClientVirtualDevice*   vd,
    int                     backup )
{
    FILE *          fh;
    char*           fname = "superbak.dmp";
    VDC_Command *   cmd;
    DWORD           completionCode;
    DWORD           bytesTransferred;
    HRESULT         hr;

    fh = fopen (fname, (backup)? "wb" : "rb");
    if (fh == NULL )
    {
        printf ("Failed to open: %s\n", fname);
        return;
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
    }

    fclose (fh);
}


