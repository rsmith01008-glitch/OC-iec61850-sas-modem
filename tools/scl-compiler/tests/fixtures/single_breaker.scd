<?xml version="1.0" encoding="UTF-8"?>
<SCL version="2007" revision="B" release="4"
     xmlns="http://www.iec.ch/61850/2003/SCL"
     xmlns:oc="urn:oc-iec61850-sas:v1">
  <Header id="single-breaker-fixture" version="1"/>

  <Communication>
    <SubNetwork name="StationBus" type="8-MMS">
      <Private type="oc-iec61850-sas">
        <oc:transport goosePort="8104"/>
      </Private>
      <ConnectedAP iedName="BRK1" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbGoose1">
          <MinTime unit="s" multiplier="m">100</MinTime>
          <MaxTime unit="s" multiplier="m">5000</MaxTime>
        </GSE>
      </ConnectedAP>
      <ConnectedAP iedName="SCADA1" apName="AP1">
        <GSE ldInst="LD0" cbName="gcbNone"/>
      </ConnectedAP>
    </SubNetwork>
  </Communication>

  <IED name="BRK1">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" integritySec="30" gooseStaleAfterSec="15" mmsPort="8102"/>
              <oc:interlock id="BRK1_VS_BRK2" localRef="XCBR1.PosCtl" blockValue="closed"
                  peerIed="BRK2" peerRef="XCBR1.Pos" condition="eq" peerValue="closed"/>
              <oc:ptocScheme name="PTOC1" input="MMXU1.Amp" trip="XCBR1.PosCtl"
                  pickup="1.2" curve="IEC_VERY_INVERSE" timeMultiplier="0.3"
                  resetSec="0.1" respectInterlocks="false"/>
            </Private>
            <DataSet name="dsGoose1">
              <FCDA lnClass="XCBR" lnInst="1" doName="Pos" fc="ST"/>
            </DataSet>
            <ReportControl name="rcbStatus1" datSet="dsGoose1" confRev="1" bufTime="0">
              <TrgOps dchg="true" qchg="true" gi="true"/>
              <OptFields/>
            </ReportControl>
            <GSEControl name="gcbGoose1" datSet="dsGoose1" appID="BRK1/gcbGoose1" type="GOOSE"/>
          </LN0>
          <LN prefix="" lnClass="XCBR" inst="1" lnType="XCBR_Basic">
            <DOI name="Pos">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0">
                  <oc:redstoneIo address="addr-status" openSide="0" closedSide="1"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="PosCtl">
              <Private type="oc-iec61850-sas">
                <oc:point>
                  <oc:redstoneIo address="addr-control" tripSide="2" closeSide="3" pulseMs="250" sboTimeoutSec="30"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
          <LN prefix="" lnClass="MMXU" inst="1" lnType="MMXU_Basic">
            <DOI name="Amp">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="0.5">
                  <oc:meterIo address="addr-ammeter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
            <DOI name="Vol">
              <Private type="oc-iec61850-sas">
                <oc:point deadband="2.0">
                  <oc:meterIo address="addr-voltmeter" method="getValue"/>
                </oc:point>
              </Private>
            </DOI>
          </LN>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>

  <IED name="SCADA1" type="SCADA">
    <AccessPoint name="AP1">
      <Server>
        <Authentication/>
        <LDevice inst="LD0">
          <LN0 lnClass="LLN0" inst="" lnType="LN0_Basic">
            <Private type="oc-iec61850-sas">
              <oc:iedSettings tickIntervalSec="0.2" resyncSec="60" connectTimeoutSec="5"
                  reconnectIntervalSec="10" gooseStaleAfterSec="15" hmsPort="8103"/>
              <oc:historian dir="/var/log/sas-scada" maxBytes="262144" maxFiles="5"/>
              <oc:alarm id="V1_LOW" ref="BRK1/LD0/MMXU1.Vol" condition="lt" value="200"
                  severity="medium" message="Bus 1 undervoltage"/>
            </Private>
          </LN0>
        </LDevice>
      </Server>
    </AccessPoint>
  </IED>

  <DataTypeTemplates>
    <LNodeType id="LN0_Basic" lnClass="LLN0">
      <DO name="Mod" type="ENC_Basic"/>
    </LNodeType>
    <LNodeType id="XCBR_Basic" lnClass="XCBR">
      <DO name="Pos" type="DPS_Basic"/>
      <DO name="PosCtl" type="DPC_Basic"/>
    </LNodeType>
    <LNodeType id="MMXU_Basic" lnClass="MMXU">
      <DO name="Amp" type="MV_Basic"/>
      <DO name="Vol" type="MV_Basic"/>
    </LNodeType>
    <DOType id="DPS_Basic" cdc="DPS">
      <DA name="stVal" fc="ST" bType="Dbpos"/>
    </DOType>
    <DOType id="DPC_Basic" cdc="DPC">
      <DA name="ctlVal" fc="CO" bType="Dbpos"/>
    </DOType>
    <DOType id="MV_Basic" cdc="MV">
      <DA name="mag" fc="MX" bType="FLOAT32"/>
    </DOType>
    <DOType id="ENC_Basic" cdc="ENC">
      <DA name="stVal" fc="ST" bType="Enum" type="ModeKind"/>
    </DOType>
    <EnumType id="ModeKind">
      <EnumVal ord="1">on</EnumVal>
    </EnumType>
  </DataTypeTemplates>
</SCL>
