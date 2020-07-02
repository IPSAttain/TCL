package provide XMLConstants 1.6

set cmd_insert insert
set cmd_delete delete
set cmd_modified modify
set cmd_appendchild appendchild
set cmd_insertbefore insertbefore
set cmd_getsubtree getsubtree
set cmd_interfaceready interfaceready
set cmd_getsystemdatabase getsystemdatabase
set cmd_putsystemdatabase putsystemdatabase
set cmd_savedatabase savedatabase
set cmd_gettemplategraphic gettemplategraphic
set cmd_export export
set cmd_confirmmessages msgconfirm
set cmd_deletemessages msgdelete
set cmd_execxpath execxpath

set XML_PreHeader "XML:"
set XML_Header "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n"

# DefaultNodeXPath

set dxp_status "/Root/Lasers/Laser/Operation/SystemState"
set dxp_actualtemplate "/Root/Lasers/Laser/Operation/ActualTemplate"
set dxp_errormessages "/Root/Lasers/Laser/Operation/ErrorMessages/ErrorMessage"
set dxp_clock "/Root/Lasers/Laser/Operation/Clock"
set dxp_templates "/Root/Databases/Database/Templates/Template"
set dxp_templatelists "/Root/Databases/Database/TemplateLists/TemplateList"
set dxp_templatebatches "/Root/Databases/Database/TemplateBatches/TemplateBatch"
set dxp_templatesequences "/Root/Databases/Database/TemplateSequences/TemplateSequence"
set dxp_configurations "/Root/Databases/Database/Configurations/Configuration"
set dxp_parametersets "/Root/Databases/Database/ParameterSets/ParameterSet"

set dxp_productcounter "/Root/Lasers/Laser/Operation/ProductCounter/ProductCounterValue"
set dxp_markingcounter "/Root/Lasers/Laser/Operation/PrintCounter/PrintCounterValue"
set dxp_globalmarkingcounter "/Root/Lasers/Laser/Operation/GlobalPrintCounter"

set dxp_lotcounter "/Root/Lasers/Laser/Operation/Lot/LotCounterValue"
set dxp_lotsize "/Root/Lasers/Laser/Operation/Lot/LotSize"

# DefaultCommands

set dc_interfaceready "<Command Action=\"interfaceready\" Location=\"\">\n</Command>"
set dc_getstatus "<Command Action=\"$cmd_getsubtree\" Location=\"$dxp_status\">\n</Command>"
set dc_start "<Command Action=\"$cmd_modified\" Location=\"$dxp_status\">\n<SystemState>LaserStatusMarking</SystemState>\n</Command>"
set dc_stop "<Command Action=\"$cmd_modified\" Location=\"$dxp_status\">\n<SystemState>LaserStatusReady</SystemState>\n</Command>"
set dc_savedatabase "<Command Action=\"$cmd_savedatabase\" Location=\"\"></Command>"

set dc_getactualtemplate "<Command Action=\"$cmd_getsubtree\" Location=\"$dxp_actualtemplate\">\n</Command>"
set dc_getmessagetextsnak "<Command Action=\"$cmd_getsubtree\" Location=\"/Root/Lasers/Laser/Operation/ErrorMessages/ErrorMessage\[Acknowledged=&quot;false&quot;\]/MessageText\"></Command>"
set dc_getmessageidsnak "<Command Action=\"$cmd_getsubtree\" Location=\"/Root/Lasers/Laser/Operation/ErrorMessages/ErrorMessage\[Acknowledged=&quot;false&quot;\]/ErrorCode\"></Command>"
set dc_confirmmessages "<Command Action=\"$cmd_confirmmessages\" Location=\"\"></Command>"
set dc_deletemessages "<Command Action=\"$cmd_deletemessages\" Location=\"\"></Command>"

set dc_getrtc "<Command Action=\"$cmd_getsubtree\" Location=\"$dxp_clock\"></Command>"

set dc_getproductcounter "<Command Action=\"$cmd_getsubtree\" Location=\"$dxp_productcounter\"></Command>"
set dc_getmarkingcounter "<Command Action=\"$cmd_getsubtree\" Location=\"$dxp_markingcounter\"></Command>"
set dc_getlotcounter "<Command Action=\"$cmd_getsubtree\" Location=\"$dxp_lotcounter\"></Command>"


# Default Errors

set dec_communicationfailed 43900
set dec_parseerror 43901
set dec_invalidstate 43902
set dec_unknowncommand 43903
set dec_parameterinvalid 43904